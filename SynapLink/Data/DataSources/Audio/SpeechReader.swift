//
//  SpeechReader.swift
//  SynapLink
//
//  On-device text-to-speech for the "read aloud" action on assistant replies.
//  Uses AVSpeechSynthesizer (fully offline, no network) — one utterance at a
//  time, toggled per message.
//

import AVFoundation
import Observation

@MainActor
@Observable
final class SpeechReader: NSObject {

    static let shared = SpeechReader()

    /// The message text currently being spoken, or nil when idle. Drives the
    /// speak/stop icon on the matching bubble.
    private(set) var spokenText: String?

    @ObservationIgnored private let synth = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synth.delegate = self
    }

    func isSpeaking(_ text: String) -> Bool { spokenText == text }

    /// Speak `text`, or stop if it's the one already playing.
    func toggle(_ text: String) {
        if spokenText == text {
            stop()
            return
        }
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)

        spokenText = text
        synth.speak(AVSpeechUtterance(string: trimmed))
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        finish()
    }

    private func finish() {
        guard spokenText != nil else { return }
        spokenText = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension SpeechReader: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }
}
