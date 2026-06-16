//
//  ChatInputBar.swift
//  SynapLink
//
//  Capability-driven message bar:
//    multimodal model →  [camera]  ( Write here )  (● voice)
//    text-only model  →            ( Write here )  (↑ send)
//  The trailing button morphs: blue voice circle when the field is empty
//  and the model hears audio; accent send arrow once there's a draft;
//  red stop while generating.
//

import SwiftUI

struct ChatInputBar: View {
    @Binding var draft: String

    let supportsVision: Bool
    let supportsAudio: Bool
    let isGenerating: Bool
    let canSend: Bool
    var hasAttachment: Bool = false

    var onSend: () -> Void
    var onStop: () -> Void
    var onCamera: () -> Void
    var onVoice: () -> Void

    @FocusState private var focused: Bool

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A turn can be sent with text, an attachment, or both.
    private var canSubmit: Bool { hasDraft || hasAttachment }

    var body: some View {
        HStack(spacing: 12) {
            if supportsVision {
                Button(action: onCamera) {
                    Image(systemName: "camera")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .disabled(isGenerating)
                .accessibilityLabel("Attach photo")
            }

            TextField("Write here", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 1)
                )
                .focused($focused)
                .disabled(isGenerating)

            trailingButton
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background {
            // The shape must run under the home indicator, or the safe-area
            // strip below the footer shows the scroll background through.
            UnevenRoundedRectangle(topLeadingRadius: 40, topTrailingRadius: 40, style: .continuous)
                .fill(.bar)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    @ViewBuilder
    private var trailingButton: some View {
        if isGenerating {
            circleButton(systemImage: "stop.fill", background: .red, action: onStop)
                .accessibilityLabel("Stop generating")
        } else if hasDraft || !supportsAudio {
            circleButton(systemImage: "arrow.up", background: Color.accentColor, action: onSend)
                .disabled(!hasDraft || !canSend)
                .accessibilityLabel("Send")
        } else {
            circleButton(systemImage: "waveform", background: .blue, action: onVoice)
                .disabled(!canSend)
                .accessibilityLabel("Voice message")
        }
    }

    private func circleButton(
        systemImage: String, background: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(background.gradient, in: Circle())
        }
    }
}

#Preview("Multimodal") {
    ChatInputBar(
        draft: .constant(""), supportsVision: true, supportsAudio: true,
        isGenerating: false, canSend: true,
        onSend: {}, onStop: {}, onCamera: {}, onVoice: {})
}

#Preview("Text only") {
    ChatInputBar(
        draft: .constant("Hello"), supportsVision: false, supportsAudio: false,
        isGenerating: false, canSend: true,
        onSend: {}, onStop: {}, onCamera: {}, onVoice: {})
}
