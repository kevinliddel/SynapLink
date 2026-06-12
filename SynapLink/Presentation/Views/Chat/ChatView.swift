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
            statusBar
            inputBar
        }
        .navigationTitle(session.activeChat?.title ?? chat.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if session.activeChat?.id != chat.id {
                session.open(chat: chat)
            }
            Task { await session.ensureEngineLoaded() }
        }
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
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

    // MARK: - Status

    @ViewBuilder
    private var statusBar: some View {
        switch session.engineState {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading model…").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(.vertical, 6)
                .padding(.horizontal)
        default:
            if let error = session.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.vertical, 6)
                    .padding(.horizontal)
            }
        }
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
                        .font(.system(size: 30))
                        .foregroundStyle(.red)
                }
            } else {
                Button {
                    let text = draft
                    draft = ""
                    session.send(text)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
