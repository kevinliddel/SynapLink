//
//  VoiceRecorder.swift
//  SynapLink
//
//  Voice-note capture for multimodal turns. Records mono LPCM WAV at the
//  model's expected sample rate — WAV because libmtmd's decoder (miniaudio)
//  reads wav/mp3/flac, not AAC containers.
//

import AVFoundation
import Observation

@MainActor
@Observable
final class VoiceRecorder {

    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    /// 0…1 smoothed input level for waveform animation.
    private(set) var level: Double = 0

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var fileURL: URL?

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start(sampleRate: Int32) throws {
        let session = AVAudioSession.sharedInstance()
        // `.measurement` disables the input-gain conditioning, which on iPhone
        // yields very quiet recordings (barely audible on playback, and too
        // weak for whisper's encoder → empty transcript). `.default` keeps the
        // standard mic processing/gain, giving speech-level audio.
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-note.wav")
        try? FileManager.default.removeItem(at: url)

        let rate = sampleRate > 0 ? Double(sampleRate) : 16000
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.record()

        self.recorder = recorder
        fileURL = url
        isRecording = true
        elapsed = 0
        startMetering()
    }

    /// Stop and return the WAV bytes (nil if nothing was captured).
    func stop() -> Data? {
        meterTask?.cancel()
        meterTask = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard let fileURL, elapsed > 0.3 else { return nil }  // ignore accidental taps
        return try? Data(contentsOf: fileURL)
    }

    func cancel() {
        _ = stop()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func startMetering() {
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                // averagePower is dBFS (-160…0); map -50…0 dB onto 0…1.
                let db = Double(recorder.averagePower(forChannel: 0))
                let normalized = max(0, min(1, (db + 50) / 50))
                self.level = self.level * 0.6 + normalized * 0.4
                self.elapsed = recorder.currentTime
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }
}
