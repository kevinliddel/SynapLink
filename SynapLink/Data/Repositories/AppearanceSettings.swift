//
//  AppearanceSettings.swift
//  SynapLink
//
//  App-wide light/dark/system appearance, persisted to UserDefaults
//  (same pattern as ChatSettings). Applied once at the window root via
//  `.preferredColorScheme`, so it flows into sheets and the chat overlay too.
//

import SwiftUI
import Observation

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    /// nil = follow the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@Observable
final class AppearanceSettings {

    static let shared = AppearanceSettings()

    private static let key = "com.synaplink.appearance"

    var mode: AppearanceMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.key) }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.key)
        mode = raw.flatMap(AppearanceMode.init) ?? .system
    }
}
