//
//  ChatView.swift
//  SynapLink
//
//  One conversation: streamed bubbles, stop, regenerate, input bar.
//

import SwiftUI

struct ChatView: View {
    let chat: Chat

    @State private var session = ChatSession.shared
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            messageList
            inputBar
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(session.activeChat?.title ?? chat.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(modelSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if session.activeChat?.id != chat.id {
                session.open(chat: chat)
            }
            Task { await session.ensureEngineLoaded() }
        }
    }

    private var modelSubtitle: String {
        switch session.engineState {
        case .loading: return "loading model…"
        case .failed: return "model unavailable"
        default: return ModelDownloadManager.shared.selectedConfig.rawValue + " · on-device"
        }
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if session.messages.isEmpty && !session.isGenerating {
                        emptyHint
                    }
                    ForEach(session.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                            .contextMenu {
                                if message.id == session.messages.last?.id,
                                   message.role == .assistant, !session.isGenerating {
                                    Button("Regenerate", systemImage: "arrow.clockwise") {
                                        session.regenerate()
                                    }
                                }
                                Button("Copy", systemImage: "doc.on.doc") {
                                    UIPasteboard.general.string = message.content
                                }
                            }
                    }
                    if session.isGenerating {
                        MessageBubble(role: .assistant, text: session.streamingText, isStreaming: true)
                            .id("streaming")
                    }
                    statusBanner
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session.streamingText) {
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
            }
            .onChange(of: session.messages.count) {
                if let last = session.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Ask anything.\nThis conversation never leaves your device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 60)
    }

    // MARK: - Status

    @ViewBuilder
    private var statusBanner: some View {
        switch session.engineState {
        case .loading:
            banner(icon: nil, text: "Loading model — first time takes a few seconds…", color: .secondary)
        case .failed(let message):
            banner(icon: "exclamationmark.triangle.fill", text: message, color: .red)
        default:
            if let error = session.lastError {
                banner(icon: "exclamationmark.triangle.fill", text: error, color: .orange)
            }
        }
    }

    private func banner(icon: String?, text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .multilineTextAlignment(.leading)
        }
        .font(.footnote)
        .foregroundStyle(color)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.vertical, 6)
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .focused($inputFocused)
                .disabled(session.isGenerating)

            if session.isGenerating {
                Button {
                    session.stop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 31))
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                }
            } else {
                Button {
                    let text = draft
                    draft = ""
                    session.send(text)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 31))
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || session.engineState == .loading)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
