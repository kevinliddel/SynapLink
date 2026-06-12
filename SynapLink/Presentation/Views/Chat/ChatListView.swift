//
//  ChatListView.swift
//  SynapLink
//
//  Home screen: chat history with search and previews, new-chat, model
//  status. First run routes straight to the Model Library — no detours
//  through Settings.
//

import SwiftUI

struct ChatListView: View {
    @State private var store = ChatStore.shared
    @State private var downloadManager = ModelDownloadManager.shared
    @State private var searchText = ""
    @State private var path: [Chat] = []
    @State private var showSettings = false
    @State private var showModelLibrary = false

    private var chats: [Chat] {
        _ = store.lastUpdated  // observe mutations
        return store.chats(matching: searchText)
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !downloadManager.isAvailable && chats.isEmpty {
                    firstRunPrompt
                } else {
                    chatList
                }
            }
            .navigationTitle("SynapLink")
            .navigationDestination(for: Chat.self) { chat in
                ChatView(chat: chat)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") {
                        showSettings = true
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Chat", systemImage: "square.and.pencil") {
                        startNewChat()
                    }
                    .disabled(!downloadManager.isAvailable)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
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
            .safeAreaInset(edge: .bottom) {
                if !downloadManager.isAvailable && !chats.isEmpty {
                    noModelBanner
                }
            }
            .onAppear { downloadManager.refreshStates() }
        }
    }

    // MARK: - Chat list

    private var chatList: some View {
        List {
            ForEach(chats) { chat in
                NavigationLink(value: chat) {
                    ChatRow(chat: chat)
                }
            }
            .onDelete { offsets in
                let current = chats
                for offset in offsets {
                    store.deleteChat(id: current[offset].id)
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Search chats")
        .overlay {
            if chats.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No chats yet" : "No results",
                    systemImage: searchText.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
                    description: Text(searchText.isEmpty
                        ? "Tap \(Image(systemName: "square.and.pencil")) to start a conversation."
                        : "Try a different search."))
            }
        }
    }

    // MARK: - Model state affordances

    private var firstRunPrompt: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "brain.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor.gradient)
            VStack(spacing: 8) {
                Text("Your private AI, fully offline")
                    .font(.title2.weight(.semibold))
                Text("Download a model once — every conversation after that stays on this device. No cloud, no account, no network.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button {
                showModelLibrary = true
            } label: {
                Label("Choose a Model", systemImage: "arrow.down.circle.fill")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
            Spacer()
        }
    }

    private var noModelBanner: some View {
        Button {
            showModelLibrary = true
        } label: {
            Label("No model installed — tap to download", systemImage: "exclamationmark.circle")
                .font(.footnote.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.orange.opacity(0.15), in: Capsule())
                .foregroundStyle(.orange)
                .padding(.horizontal)
        }
        .padding(.bottom, 6)
    }

    private func startNewChat() {
        if let chat = ChatSession.shared.startNewChat() {
            path.append(chat)
        }
    }
}

private struct ChatRow: View {
    let chat: Chat

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor.opacity(0.85))
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(chat.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text(chat.updatedAt, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var preview: String {
        guard let last = ChatStore.shared.lastMessage(chatID: chat.id) else {
            return "No messages yet"
        }
        let prefix = last.role == .user ? "You: " : ""
        return prefix + last.content.replacingOccurrences(of: "\n", with: " ")
    }
}

#Preview {
    ChatListView()
}
