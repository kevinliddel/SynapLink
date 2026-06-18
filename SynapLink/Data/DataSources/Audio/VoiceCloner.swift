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

    private static let pauseMap: [Character: Double] = [
        ",": 0.18, ";": 0.18, ":": 0.18, ".": 0.40, "!": 0.40, "?": 0.40
    ]
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
            let (phones, tones, langs) = g2p.encode(chunk.text)
            guard var audio = synth(handle: handle, phones: phones, tones: tones, langs: langs, tgt: tgt) else { continue }
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
              let h = synap_voice_create(melo.path, conv.path),
              let src = bundledF32("se_source_en"),
              let g = G2P() else {
            slog("voice: model/g2p load failed", .error)
            return false
        }
        handle = h
        srcSE = src
        g2p = g
        return true
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

    private func synth(handle: OpaquePointer, phones: [Int64], tones: [Int64], langs: [Int64],
                       tgt: [Float]) -> [Float]? {
        var out: UnsafeMutablePointer<Float>?
        let n = phones.withUnsafeBufferPointer { p in
            tones.withUnsafeBufferPointer { t in
                langs.withUnsafeBufferPointer { l in
                    srcSE.withUnsafeBufferPointer { s in
                        tgt.withUnsafeBufferPointer { g in
                            synap_voice_say(handle, p.baseAddress, t.baseAddress, l.baseAddress,
                                            Int32(phones.count), 0, s.baseAddress, g.baseAddress, &out)
                        }
                    }
                }
            }
        }
        guard n > 0, let out else { return nil }
        defer { synap_voice_free_audio(out) }
        return Array(UnsafeBufferPointer(start: out, count: Int(n)))
    }

    private struct Chunk { let text: String; let pause: Double }

    private func chunkize(_ text: String) -> [Chunk] {
        var chunks: [Chunk] = []
        var buf = ""
        for ch in text {
            buf.append(ch)
            if let pause = Self.pauseMap[ch] {
                let trimmed = buf.trimmingCharacters(in: .whitespaces)
                if trimmed.count > 1 { chunks.append(Chunk(text: trimmed, pause: pause)) }
                buf = ""
            }
        }
        let tail = buf.trimmingCharacters(in: .whitespaces)
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
            player.play()
            self.engine = engine
            self.player = player
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
    }
}
