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
        slog("whisper input: \(fileBytes) B file → \(samples.count) samples, "
            + "peak \(String(format: "%.3f", peak)), gpu=\(RuntimeProfile.whisperUsesGPU)",
            samples.isEmpty || peak < 0.001 ? .warning : .info)

        // Normalize quiet recordings to a healthy level — whisper's encoder
        // needs speech-level input; a low-amplitude clip yields zero segments.
        if peak > 0.001 && peak < 0.7 {
            let gain = 0.95 / peak
            for index in samples.indices { samples[index] *= gain }
            slog("whisper: boosted level ×\(String(format: "%.1f", gain))", .info)
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

    /// Decode any recorded clip to the mono float32 @ 16 kHz that whisper wants.
    private static func decodeToMono16kFloat(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(SYNAP_WHISPER_SAMPLE_RATE),
            channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw WhisperError.audioDecodeFailed
        }

        // Read the whole source file into one buffer.
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw WhisperError.audioDecodeFailed
        }
        try file.read(into: inputBuffer)

        // Resample/downmix to 16 kHz mono.
        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(frameCount) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else {
            throw WhisperError.audioDecodeFailed
        }

        var fed = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
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
