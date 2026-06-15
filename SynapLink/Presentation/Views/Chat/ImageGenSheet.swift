//
//  ImageGenSheet.swift
//  SynapLink
//
//  Prompt entry for the experimental on-device image generator.
//

import SwiftUI

struct ImageGenSheet: View {
    var onGenerate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @FocusState private var focused: Bool

    private var experimentalOn4GB: Bool {
        RuntimeProfile.physicalMemoryGB < 5.0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Describe the image…", text: $prompt, axis: .vertical)
                        .lineLimit(2...5)
                        .focused($focused)
                } footer: {
                    Text("Generated entirely on your device.")
                }

                if experimentalOn4GB {
                    Section {
                        Label(
                            "Experimental on this device — generation can take a minute or two and quality is limited.",
                            systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Create Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") {
                        let text = prompt
                        dismiss()
                        onGenerate(text)
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    Color.black.sheet(isPresented: .constant(true)) {
        ImageGenSheet { _ in }
    }
}
