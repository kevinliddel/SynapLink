//
//  SettingsView.swift
//  SynapLink
//
//  Appearance, system prompt, generation limits, model library, diagnostics.
//  A profile header up top mirrors the Home greeting; rows use colored icon
//  tiles in the iOS-settings idiom.
//

import SwiftUI

struct SettingsView: View {
    @State private var settings = ChatSettings.shared
    @State private var appearance = AppearanceSettings.shared
    @State private var voiceSettings = VoiceSettings.shared
    @State private var showModelLibrary = false

    // Phase 4 will pull the real profile name; placeholder for now.
    private let userName = "User"

    // Cloned voices appear only when their models are bundled.
    private var readAloudVoices: [ReadAloudVoice] {
        VoiceCloner.shared.isAvailable ? ReadAloudVoice.allCases : [.system]
    }

    var body: some View {
        NavigationStack {
            Form {
                profileHeader

                Section {
                    HStack {
                        Label {
                            Text("Theme")
                        } icon: {
                            rowIcon("circle.lefthalf.filled", .blue)
                        }
                        Spacer()
                        ThemeSwitcher(mode: Bindable(appearance).mode)
                    }
                } header: {
                    Text("Appearance")
                }

                Section {
                    Picker(selection: Bindable(voiceSettings).voice) {
                        ForEach(readAloudVoices) { option in
                            Text(option.gender.map { "\(option.label) · \($0)" } ?? option.label)
                                .tag(option)
                        }
                    } label: {
                        Label {
                            Text("Read-aloud voice")
                        } icon: {
                            rowIcon("speaker.wave.2.fill", .purple)
                        }
                    }
                } header: {
                    Text("Voice")
                }

                Section("Models") {
                    Button {
                        showModelLibrary = true
                    } label: {
                        Label {
                            Text("Model Library")
                        } icon: {
                            rowIcon("square.stack.3d.up.fill", .indigo)
                        }
                    }
                    .tint(.primary)
                }

                Section {
                    TextEditor(text: Bindable(settings).systemPrompt)
                        .frame(minHeight: 120)
                        .font(.callout)
                    Button("Reset to Default") {
                        settings.resetSystemPrompt()
                    }
                    .font(.caption)
                } header: {
                    Text("System Prompt")
                }

                Section("Generation") {
                    Stepper(value: Bindable(settings).maxNewTokens, in: 128...2048, step: 128) {
                        HStack {
                            Text("Max reply length")
                            Spacer()
                            Text("\(settings.maxNewTokens) tok")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Diagnostics") {
                    NavigationLink {
                        SmokeTestView()
                    } label: {
                        Label {
                            Text("Performance Test")
                        } icon: {
                            rowIcon("speedometer", .orange)
                        }
                    }
                }

                aboutFooter
            }
            .scrollIndicators(.hidden)
            .synapTabBarInset()
            .navigationTitle("Settings")
            .sheet(isPresented: $showModelLibrary) {
                NavigationStack {
                    ModelLibraryView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showModelLibrary = false }
                            }
                        }
                }
            }
        }
    }

    // MARK: - Header / footer

    private var profileHeader: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(userName)
                        .font(.title3.weight(.semibold))
                    Text("On-device · Private")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var aboutFooter: some View {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(version).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Row icon

    private func rowIcon(_ system: String, _ tint: Color) -> some View {
        Image(systemName: system)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

// MARK: - Theme switcher

/// Compact sliding sun/moon toggle. The stored default is `.system`; tapping
/// commits an explicit `.light` or `.dark`. The knob mirrors the *effective*
/// scheme, so in `.system` it tracks the device setting until the user picks.
private struct ThemeSwitcher: View {
    @Binding var mode: AppearanceMode
    @Environment(\.colorScheme) private var systemScheme

    private let knob: CGFloat = 30

    private var isDark: Bool {
        switch mode {
        case .dark: return true
        case .light: return false
        case .system: return systemScheme == .dark
        }
    }

    var body: some View {
        ZStack {
            Capsule().fill(Color(.tertiarySystemFill))

            // Sliding knob sits behind the icons.
            HStack(spacing: 0) {
                if isDark { Spacer(minLength: 0) }
                Circle()
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    .frame(width: knob, height: knob)
                if !isDark { Spacer(minLength: 0) }
            }
            .padding(3)

            HStack(spacing: 0) {
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(
                        isDark ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange)
                    )
                    .frame(maxWidth: .infinity)
                Image(systemName: "moon.fill")
                    .foregroundStyle(
                        isDark ? AnyShapeStyle(Color.indigo) : AnyShapeStyle(.secondary)
                    )
                    .frame(maxWidth: .infinity)
            }
            .font(.system(size: 13, weight: .bold))
        }
        .frame(width: 72, height: knob + 6)
        .contentShape(Capsule())
        .onTapGesture {
            withAnimation(.snappy(duration: 0.22)) { mode = isDark ? .light : .dark }
        }
        .accessibilityElement()
        .accessibilityLabel("Theme")
        .accessibilityValue(isDark ? "Dark" : "Light")
        .accessibilityAddTraits(.isButton)
    }
}

#Preview {
    SettingsView()
}
