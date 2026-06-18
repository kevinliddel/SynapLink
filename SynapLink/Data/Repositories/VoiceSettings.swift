//
//  VoiceSettings.swift
//  SynapLink
//
//  The read-aloud voice: the system AVSpeech voice, or one of the cloned
//  voices. Persisted to UserDefaults; drives the speaker button on AI replies.
//

import Foundation
import Observation

enum ReadAloudVoice: String, CaseIterable, Identifiable {
    case system, riko, akira, touma, ayanokoji

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .riko: return "Riko"
        case .akira: return "Akira"
        case .touma: return "Touma"
        case .ayanokoji: return "Ayanokoji"
        }
    }

    /// Female / Male tag for the cloned voices (nil for System).
    var gender: String? {
        switch self {
        case .system: return nil
        case .riko, .akira: return "Female"
        case .touma, .ayanokoji: return "Male"
        }
    }

    var isCloned: Bool { self != .system }

    /// Bundled 256-float speaker embedding resource (e.g. "se_riko"), nil for System.
    var embeddingResource: String? { isCloned ? "se_\(rawValue)" : nil }
}

@MainActor
@Observable
final class VoiceSettings {

    static let shared = VoiceSettings()

    private static let key = "com.synaplink.readAloudVoice"

    var voice: ReadAloudVoice {
        didSet { UserDefaults.standard.set(voice.rawValue, forKey: Self.key) }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.key)
        voice = raw.flatMap(ReadAloudVoice.init) ?? .system
    }
}
