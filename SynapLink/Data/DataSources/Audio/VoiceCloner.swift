//
//  VoiceCloner.swift
//  SynapLink
//
//  Cloned-voice TTS engine: text -> G2P -> chunk at punctuation -> synap_voice
//  (MeloTTS no-BERT + tone-color converter, ONNX) per chunk -> pipelined
//  playback (start chunk 1 while the rest synthesize). Models + g2p load lazily
//  once and stay resident. SpeechReader routes the read-aloud button here when a
//  cloned voice is selected.
//

import AVFoundation
import Foundation

final class VoiceCloner {

    static let shared = VoiceCloner()

    private let queue = DispatchQueue(label: "com.dedicatus.synaplink.voice", qos: .userInitiated)
    private let lock = NSLock()
    private var jobID = 0

    private var handle: OpaquePointer?
    private var g2p: G2P?
    private var srcSE: [Float] = []
    private var seCache: [String: [Float]] = [:]

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var bufferedForStart = 0.0  // main-thread: audio queued before play starts
    private var playStarted = false

    // Gap inserted *after* trimming each chunk's silence on both ends, so these
    // are the entire inter-chunk pause. Kept short — the synthesized punctuation
    // already carries most of the prosodic break.
    private static let pauseMap: [Character: Double] = [
        ",": 0.05, ";": 0.06, ":": 0.06, ".": 0.12, "!": 0.12, "?": 0.12
    ]
    private static let sentenceEnders: Set<Character> = [".", "!", "?"]
    private static let maxChunkChars = 200
    /// Audio buffered before playback starts. Synthesis runs faster than real
    /// time, so this head start lets the queue stay ahead and prevents the
    /// underrun gaps heard when a short sentence precedes a long one (e.g. across
    /// paragraphs). Short replies start as soon as the last chunk is ready.
    private static let startCushion: Double = 1.5
    private let sampleRate = Double(synap_voice_sample_rate())

    private init() {}

    /// True once load has succeeded (used to gate the cloned option if assets are absent).
    var isAvailable: Bool {
        Bundle.main.url(forResource: "melo_en", withExtension: "onnx") != nil
    }

    /// Speak `text` in the cloned `voice`. `onFinish` runs on the main queue when
    /// playback completes (or is superseded). No-op for a non-cloned voice.
    func speak(_ text: String, voice: ReadAloudVoice, onFinish: @escaping () -> Void) {
        guard let embedding = voice.embeddingResource else { onFinish(); return }
        lock.lock(); jobID += 1; let job = jobID; lock.unlock()
        queue.async { [weak self] in self?.run(text: text, embedding: embedding, job: job, onFinish: onFinish) }
    }

    func stop() {
        lock.lock(); jobID += 1; lock.unlock()  // invalidate any running job
        let player = self.player, engine = self.engine
        DispatchQueue.main.async {
            player?.stop()
            engine?.stop()
        }
        self.player = nil
        self.engine = nil
    }

    private func isCurrent(_ job: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return job == jobID
    }

    private func run(text: String, embedding: String, job: Int, onFinish: @escaping () -> Void) {
        guard load(), let g2p, let handle, let tgt = targetSE(embedding) else {
            DispatchQueue.main.async(execute: onFinish)
            return
        }
        let chunks = chunkize(text)
        guard !chunks.isEmpty else { DispatchQueue.main.async(execute: onFinish); return }

        startEngine(job: job)
        for (index, chunk) in chunks.enumerated() {
            if !isCurrent(job) { return }  // stopped / superseded
            let enc = g2p.encode(chunk.text)
            let t0 = DispatchTime.now().uptimeNanoseconds
            guard var audio = synth(handle: handle, enc: enc, tgt: tgt) else { continue }
            let synthSec = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e9
            audio = Self.trimSilence(audio)
            guard !audio.isEmpty else { continue }
            let audioSec = Double(audio.count) / sampleRate
            slog(String(format: "voice chunk %d/%d: %.2fs audio in %.2fs (%.2fx rt) +%.2fs pause [%d ids]",
                        index + 1, chunks.count, audioSec, synthSec,
                        audioSec / max(synthSec, 0.001), chunk.pause, enc.inputIds.count), .notice)
            if chunk.pause > 0 {
                audio.append(contentsOf: repeatElement(0, count: Int(chunk.pause * sampleRate)))
            }
            let isLast = index == chunks.count - 1
            DispatchQueue.main.async { [weak self] in
                self?.schedule(audio, job: job, last: isLast, onFinish: onFinish)
            }
        }
    }

    // MARK: - Load

    private func load() -> Bool {
        if handle != nil { return true }
        guard let melo = Bundle.main.url(forResource: "melo_en", withExtension: "onnx"),
              let conv = Bundle.main.url(forResource: "voice_conversion", withExtension: "onnx"),
              let src = bundledF32("se_source_en"),
              let g = G2P() else {
            slog("voice: model/g2p load failed", .error)
            return false
        }
        // Optional prosody BERT — absent => intonation off, voice still works.
        let bert = Bundle.main.url(forResource: "bert_en", withExtension: "onnx")?.path
        guard let h = makeHandle(melo: melo.path, converter: conv.path, bert: bert) else {
            slog("voice: engine create failed", .error)
            return false
        }
        handle = h
        srcSE = src
        g2p = g
        return true
    }

    /// String args auto-bridge to C strings; the optional bert path needs the branch.
    private func makeHandle(melo: String, converter: String, bert: String?) -> OpaquePointer? {
        if let bert { return synap_voice_create(melo, converter, bert) }
        return synap_voice_create(melo, converter, nil)
    }

    private func targetSE(_ name: String) -> [Float]? {
        if let cached = seCache[name] { return cached }
        guard let se = bundledF32(name) else { return nil }
        seCache[name] = se
        return se
    }

    private func bundledF32(_ name: String) -> [Float]? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "f32"),
              let data = try? Data(contentsOf: url) else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    // MARK: - Synthesis

    private func synth(handle: OpaquePointer, enc: G2P.Encoded, tgt: [Float]) -> [Float]? {
        var out: UnsafeMutablePointer<Float>?
        let n = enc.phones.withUnsafeBufferPointer { p in
            enc.tones.withUnsafeBufferPointer { t in
                enc.langs.withUnsafeBufferPointer { l in
                    srcSE.withUnsafeBufferPointer { s in
                        tgt.withUnsafeBufferPointer { g in
                            enc.inputIds.withUnsafeBufferPointer { ids in
                                enc.word2ph.withUnsafeBufferPointer { w2p in
                                    synap_voice_say(
                                        handle, p.baseAddress, t.baseAddress, l.baseAddress,
                                        Int32(enc.phones.count), 0, s.baseAddress, g.baseAddress,
                                        ids.baseAddress, w2p.baseAddress, Int32(enc.inputIds.count),
                                        &out)
                                }
                            }
                        }
                    }
                }
            }
        }
        guard n > 0, let out else { return nil }
        defer { synap_voice_free_audio(out) }
        return Array(UnsafeBufferPointer(start: out, count: Int(n)))
    }

    /// MeloTTS pads every chunk with leading + trailing near-silence (the "_"
    /// pad + SDP-variable blank durations), which made inter-chunk gaps long and
    /// uneven. Trim BOTH ends to the audible region (+ a short margin) so the
    /// pauseMap gap is the only silence between chunks. Empty if all silence.
    private static func trimSilence(_ audio: [Float], threshold: Float = 0.015,
                                    margin: Int = 160) -> [Float] {
        guard let first = audio.firstIndex(where: { abs($0) > threshold }),
              let last = audio.lastIndex(where: { abs($0) > threshold }) else { return [] }
        let start = max(0, first - margin)
        let end = min(audio.count, last + margin + 1)
        return Array(audio[start..<end])
    }

    private struct Chunk { let text: String; let pause: Double }

    /// Split at SENTENCE boundaries (. ! ?) so melo + BERT see the whole
    /// sentence — far better intonation, and commas are voiced natively instead
    /// of fragmenting prosody. Very long sentences soft-break at a comma/space
    /// past maxChunkChars to bound time-to-first-audio.
    private func chunkize(_ text: String) -> [Chunk] {
        var chunks: [Chunk] = []
        var buf = ""
        func flush(_ pause: Double) {
            let trimmed = buf.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > 1 { chunks.append(Chunk(text: trimmed, pause: pause)) }
            buf = ""
        }
        for ch in text {
            buf.append(ch)
            if Self.sentenceEnders.contains(ch) {
                flush(Self.pauseMap[ch] ?? 0.12)
            } else if buf.count >= Self.maxChunkChars, ch == "," || ch == ";" || ch == " " {
                flush(Self.pauseMap[ch] ?? 0.05)
            }
        }
        let tail = buf.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { chunks.append(Chunk(text: tail, pause: 0)) }
        return chunks
    }

    // MARK: - Playback (main queue)

    private func startEngine(job: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(job) else { return }
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            guard let format = AVAudioFormat(standardFormatWithSampleRate: self.sampleRate, channels: 1) else { return }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                try AVAudioSession.sharedInstance().setActive(true)
                try engine.start()
            } catch {
                slog("voice: audio engine failed — \(error.localizedDescription)", .error)
                return
            }
            self.engine = engine
            self.player = player
            self.bufferedForStart = 0
            self.playStarted = false  // play() deferred until the cushion fills (see schedule)
        }
    }

    private func schedule(_ samples: [Float], job: Int, last: Bool, onFinish: @escaping () -> Void) {
        guard isCurrent(job), let player, let engine,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              engine.isRunning else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        player.scheduleBuffer(buffer) { [weak self] in
            guard last else { return }
            DispatchQueue.main.async {
                if self?.isCurrent(job) == true { onFinish() }
            }
        }
        // Defer playback until enough is queued (or it's the final chunk) so the
        // player keeps a lead over synthesis and doesn't underrun between chunks.
        bufferedForStart += Double(samples.count) / sampleRate
        if !playStarted, bufferedForStart >= Self.startCushion || last {
            player.play()
            playStarted = true
            slog(String(format: "voice playback start: %.2fs buffered", bufferedForStart), .notice)
        }
    }
}
