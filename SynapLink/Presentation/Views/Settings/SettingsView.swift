//
//  SettingsView.swift
//  SynapLink
//
//  System prompt, generation limits, model library, diagnostics.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ChatSettings.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Models") {
                    NavigationLink {
                        ModelLibraryView()
                    } label: {
                        Label("Model Library", systemImage: "square.stack.3d.up")
                    }
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
                } footer: {
                    Text("Sent at the start of every conversation.")
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
                        Label("Inference Smoke Test", systemImage: "speedometer")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
