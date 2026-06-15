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
        let samples = try Self.decodeToMono16kFloat(url: fileURL)

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let handle = synap_whisper_create(
                    model.path, RuntimeProfile.specialistUsesGPU, RuntimeProfile.specialistThreads) else {
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
                    continuation.resume(throwing: WhisperError.transcriptionFailed)
                } else {
                    continuation.resume(returning: String(cString: buffer))
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
