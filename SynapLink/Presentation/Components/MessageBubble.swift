//
//  MessageBubble.swift
//  SynapLink
//
//  One chat message. Assistant text renders inline markdown (bold, italics,
//  code, links) via AttributedString — block elements (headings, lists)
//  arrive as separate lines and read fine as styled text on Phase 1's
//  baseline; a full markdown layout engine is deliberately out of scope.
//

import SwiftUI

struct MessageBubble: View {
    let role: MessageRole
    let text: String
    var isStreaming = false
    var attachments: [Attachment] = []

    var body: some View {
        HStack {
            if role == .user { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 8) {
                attachmentViews
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            if role == .assistant { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder
    private var attachmentViews: some View {
        ForEach(attachments) { attachment in
            switch attachment.kind {
            case .image:
                if let url = ChatStore.shared.attachmentURL(attachment),
                   let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        } else if role == .assistant {
            if isStreaming {
                // Plain, smoothly-revealed text while generating — markdown is
                // applied once the reply settles (avoids per-token reflow).
                StreamingText(fullText: text)
            } else {
                // Block markdown: fenced code with copy button, headings, inline styles.
                MarkdownText(text: text)
                    .textSelection(.enabled)
                    .transition(.opacity)
            }
        } else {
            Text(MarkdownText.inline(text))
                .textSelection(.enabled)
                .tint(.white)
        }
    }

    private var background: some ShapeStyle {
        role == .user
            ? AnyShapeStyle(Color.accentColor)
            : AnyShapeStyle(Color(.secondarySystemBackground))
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

extension MessageBubble {
    init(message: Message) {
        self.init(role: message.role,
                  text: message.content,
                  attachments: message.attachments)
    }
}

#Preview {
    VStack(spacing: 12) {
        MessageBubble(role: .user, text: "Why is the sky **blue**?")
        MessageBubble(role: .assistant, text: "Because of *Rayleigh scattering* — shorter `wavelengths` scatter more.")
        MessageBubble(role: .assistant, text: "", isStreaming: true)
    }
    .padding()
}
