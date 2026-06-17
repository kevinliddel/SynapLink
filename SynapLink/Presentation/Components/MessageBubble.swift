//
//  MessageBubble.swift
//  SynapLink
//
//  One chat message. The user's turn is a compact accent-colored bubble
//  (right-aligned, any image shown above it); the assistant's reply is a
//  full-width card with an action row (copy / read-aloud / regenerate).
//  Assistant text renders block markdown when settled, smoothly-revealed plain
//  text while streaming.
//

import SwiftUI

struct MessageBubble: View {
    let role: MessageRole
    let text: String
    var isStreaming = false
    var attachments: [Attachment] = []
    /// Non-nil on the latest assistant reply → shows the regenerate action.
    var onRegenerate: (() -> Void)?

    @State private var speech = SpeechReader.shared
    @State private var preview: PreviewImage?

    var body: some View {
        Group {
            if role == .user {
                userMessage
            } else {
                assistantMessage
            }
        }
        .fullScreenCover(item: $preview) { ImageViewer(image: $0.image) }
    }

    // MARK: - User

    /// Rounded on three corners; the bottom-trailing corner is squared off so
    /// the bubble reads as the sender's (points to the right edge).
    private static let userBubbleShape = UnevenRoundedRectangle(
        topLeadingRadius: 22, bottomLeadingRadius: 22,
        bottomTrailingRadius: 4, topTrailingRadius: 22, style: .continuous)

    private var userMessage: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 8) {
                attachmentViews
                if !text.isEmpty {
                    Text(MarkdownText.inline(text))
                        .foregroundStyle(.white)
                        .tint(.white)
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(Color.accentColor.gradient, in: Self.userBubbleShape)
                }
            }
        }
    }

    // MARK: - Assistant

    private var assistantMessage: some View {
        // Image sits OUTSIDE the card (left-aligned, like the user's image);
        // only the text/actions live in the full-width card.
        VStack(alignment: .leading, spacing: 8) {
            attachmentViews
            if hasText || isStreaming {
                textCard
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var textCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
            if showActions {
                Divider()
                actionRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showActions: Bool {
        role == .assistant && !isStreaming && hasText
    }

    private var actionRow: some View {
        // Copy and read-aloud operate on the markdown flattened to plain text,
        // so neither pastes nor reads raw syntax (** , #, `code`, link URLs…).
        let plain = MarkdownText.plain(text)
        return HStack(spacing: 22) {
            iconButton("doc.on.doc", "Copy") { UIPasteboard.general.string = plain }
            iconButton(speech.isSpeaking(plain) ? "stop.fill" : "speaker.wave.2",
                       "Read aloud") { speech.toggle(plain) }
            Spacer()
            if let onRegenerate {
                iconButton("arrow.clockwise", "Regenerate", action: onRegenerate)
            }
        }
        .padding(.top, 2)
    }

    private func iconButton(_ systemName: String, _ label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Attachments & content

    @ViewBuilder
    private var attachmentViews: some View {
        ForEach(attachments) { attachment in
            switch attachment.kind {
            case .image:
                if let url = ChatStore.shared.attachmentURL(attachment),
                   let image = UIImage(contentsOfFile: url.path) {
                    // Width-only constraint so the frame HUGS the image (a 2-D
                    // frame + scaledToFit would letterbox, rounding the empty
                    // box instead of the picture).
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .onTapGesture { preview = PreviewImage(image: image) }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("Open image")
                }
            case .audio:
                if let url = ChatStore.shared.attachmentURL(attachment) {
                    AudioAttachmentView(url: url)
                        .tint(role == .user ? .white : .accentColor)
                        .foregroundStyle(role == .user ? .white : .primary)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if text.isEmpty && isStreaming {
            TypingIndicator()
        } else if text.isEmpty {
            EmptyView()
        } else if isStreaming {
            // Plain, smoothly-revealed text while generating — markdown is
            // applied once the reply settles (avoids per-token reflow).
            StreamingText(fullText: text)
        } else {
            // Block markdown: fenced code with copy button, headings, inline styles.
            MarkdownText(text: text)
                .textSelection(.enabled)
                .transition(.opacity)
        }
    }
}

/// Three pulsing dots shown while the first token is still on its way.
struct TypingIndicator: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 7, height: 7)
                    .opacity(phase ? 1 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever()
                            .delay(Double(index) * 0.2),
                        value: phase)
            }
        }
        .foregroundStyle(.secondary)
        .onAppear { phase = true }
    }
}

/// A tapped image being shown full-screen (Identifiable for `fullScreenCover`).
private struct PreviewImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

extension MessageBubble {
    init(message: Message, onRegenerate: (() -> Void)? = nil) {
        self.init(role: message.role,
                  text: message.content,
                  attachments: message.attachments,
                  onRegenerate: onRegenerate)
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 12) {
            MessageBubble(role: .user, text: "Why is the sky **blue**?")
            MessageBubble(role: .assistant,
                          text: "Because of *Rayleigh scattering* — shorter `wavelengths` scatter more.",
                          onRegenerate: {})
            MessageBubble(role: .assistant, text: "", isStreaming: true)
        }
        .padding()
    }
}
