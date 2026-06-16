//
//  WhisperTranscriber.swift
//  SynapLink
//
//  On-demand speech-to-text via the whisper.cpp bridge. A specialist in the
//  sidecar pipeline: load model → transcribe one clip → unload, so it only
//  occupies RAM while actually working (the main chat model stays resident).
//

import AVFoundation
import Foundation

enum WhisperError: Error, LocalizedError {
    case modelNotInstalled
    case loadFailed
    case audioDecodeFailed
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled: return "The speech model isn't installed. Download it in the Model Library."
        case .loadFailed: return "Failed to load the speech model."
        case .audioDecodeFailed: return "Couldn't read the recorded audio."
        case .transcriptionFailed: return "Transcription failed."
        }
    }
}

final class WhisperTranscriber: @unchecked Sendable {

    static let shared = WhisperTranscriber()

    private let queue = DispatchQueue(label: "com.dedicatus.synaplink.whisper", qos: .userInitiated)

    private init() {}

    /// Transcribe a recorded audio file (any AVFoundation-decodable format).
    /// Loads the whisper model, runs, and unloads before returning.
    func transcribe(fileURL: URL, languageCode: String? = nil) async throws -> String {
        guard let model = SpecialistModel.whisper.modelURL() else {
            throw WhisperError.modelNotInstalled
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileBytes = (attrs?[.size] as? Int) ?? 0
        var samples = try Self.decodeToMono16kFloat(url: fileURL)
        let peak = samples.map { abs($0) }.max() ?? 0
        let rms = samples.isEmpty ? 0
            : sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
        slog("whisper input: \(fileBytes) B file → \(samples.count) samples, "
            + "peak \(String(format: "%.3f", peak)), rms \(String(format: "%.4f", rms)), "
            + "gpu=\(RuntimeProfile.whisperUsesGPU)",
            samples.isEmpty || rms < 0.005 ? .warning : .info)

        // Normalize to a target speech ENERGY (RMS), not peak: a transient
        // click can pin the peak near 1.0 while the actual speech stays far too
        // quiet for whisper's encoder (→ zero segments). Gain is clamped so
        // near-silence isn't blown up, and the result is clipped back in range.
        if rms > 0.0001 {
            let targetRMS: Float = 0.12
            let gain = min(targetRMS / rms, 40)
            if gain > 1.05 {
                for index in samples.indices {
                    samples[index] = max(-1, min(1, samples[index] * gain))
                }
                slog("whisper: boosted to target RMS (×\(String(format: "%.1f", gain)))", .info)
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let handle = synap_whisper_create(
                    model.path, RuntimeProfile.whisperUsesGPU, RuntimeProfile.specialistThreads) else {
                    slog("whisper model load failed", .error)
                    continuation.resume(throwing: WhisperError.loadFailed)
                    return
                }
                defer { synap_whisper_free(handle) }

                var buffer = [CChar](repeating: 0, count: 8 * 1024)
                let written = samples.withUnsafeBufferPointer { ptr in
                    synap_whisper_transcribe(
                        handle, ptr.baseAddress, Int32(ptr.count),
                        languageCode, &buffer, Int32(buffer.count))
                }
                if written < 0 {
                    slog("whisper transcription failed (rc \(written))", .error)
                    continuation.resume(throwing: WhisperError.transcriptionFailed)
                } else {
                    let text = String(cString: buffer)
                    let seconds = samples.count / Int(SYNAP_WHISPER_SAMPLE_RATE)
                    slog("transcribed \(seconds)s of audio → \(text.count) chars", .info)
                    continuation.resume(returning: text)
                }
            }
        }
    }

    // MARK: - Audio decode

    /// Decode a recorded clip to mono float32 @ 16 kHz. We record at 16 kHz mono
    /// already, so the fast path reads the float samples straight out of the
    /// file — exactly the data the (proven) desktop smoke test feeds whisper.
    /// `AVAudioConverter` is used ONLY when the source rate genuinely differs.
    private static func decodeToMono16kFloat(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw WhisperError.audioDecodeFailed
        }
        try file.read(into: buffer)

        guard let channels = buffer.floatChannelData else { throw WhisperError.audioDecodeFailed }
        let channelCount = Int(format.channelCount)
        let frames = Int(buffer.frameLength)

        // Downmix to mono.
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for index in 0..<frames { mono[index] += samples[index] }
        }
        if channelCount > 1 {
            let scale = 1.0 / Float(channelCount)
            for index in 0..<frames { mono[index] *= scale }
        }

        let nativeRate = format.sampleRate
        slog("whisper decode: \(String(format: "%.0f", nativeRate)) Hz, "
            + "\(channelCount) ch, \(frames) frames", .info)

        let targetRate = Double(SYNAP_WHISPER_SAMPLE_RATE)
        if abs(nativeRate - targetRate) < 1 {
            return mono  // already 16 kHz — direct, matches the desktop path
        }
        return try resample(mono, from: nativeRate, to: targetRate)
    }

    /// Resample mono float samples with `AVAudioConverter` (anti-aliased),
    /// draining until it stops producing output.
    private static func resample(_ input: [Float], from sourceRate: Double, to targetRate: Double) throws -> [Float] {
        guard let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sourceRate,
                channels: 1, interleaved: false),
              let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
              let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(input.count)) else {
            throw WhisperError.audioDecodeFailed
        }
        inputBuffer.frameLength = AVAudioFrameCount(input.count)
        if let dst = inputBuffer.floatChannelData?[0] {
            input.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: input.count) }
        }

        let ratio = targetRate / sourceRate
        let capacity = AVAudioFrameCount(Double(input.count) * ratio) + 4096
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw WhisperError.audioDecodeFailed
        }
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return inputBuffer
        }
        if conversionError != nil { throw WhisperError.audioDecodeFailed }
        guard let channel = outputBuffer.floatChannelData?[0] else {
            throw WhisperError.audioDecodeFailed
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
    }
}
