//
//  SpeechReader.swift
//  SynapLink
//
//  On-device text-to-speech for the "read aloud" action on assistant replies.
//  Uses AVSpeechSynthesizer (fully offline, no network) — one utterance at a
//  time, toggled per message.
//
//  Voice quality: the synthesizer otherwise defaults to the robotic "compact"
//  voice, so we pick the best installed voice — the user's Personal Voice if
//  they've set one up (Settings ▸ Accessibility ▸ Personal Voice), else the
//  highest-quality premium/enhanced voice for their language. There is NO API
//  to build a voice from an audio file; Personal Voice is the user's own,
//  created only through that system flow. For natural prosody, download an
//  Enhanced/Premium voice in Settings ▸ Accessibility ▸ Spoken Content ▸ Voices.
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
    @ObservationIgnored private var personalVoiceRequested = false

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

        // Authorize Personal Voice once; it becomes usable on the next utterance.
        if !personalVoiceRequested {
            personalVoiceRequested = true
            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { _ in }
        }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = Self.preferredVoice()
        utterance.pitchMultiplier = 1.0
        spokenText = text
        synth.speak(utterance)
    }

    /// Best installed voice: Personal Voice if authorized, else the highest
    /// quality (premium > enhanced > default) for the current language,
    /// preferring an exact locale match and skipping novelty voices.
    private static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let personal = voices.first(where: { $0.voiceTraits.contains(.isPersonalVoice) }) {
            return personal
        }
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let prefix = String(language.prefix(2))
        let best = voices
            .filter { $0.language == language || $0.language.hasPrefix(prefix) }
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
            .max { lhs, rhs in
                if lhs.language != rhs.language {
                    // Exact locale wins over a same-language regional variant.
                    return lhs.language != language && rhs.language == language
                }
                return lhs.quality.rawValue < rhs.quality.rawValue
            }
        return best ?? AVSpeechSynthesisVoice(language: language)
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
