//
//  ChatListView.swift
//  SynapLink
//
//  Chat tab: conversation history with search and previews, plus new-chat.
//  First-run model setup lives on the Home tab; this tab opens chats handed
//  to it by the router (e.g. when Home starts a chat or an image generation).
//

import SwiftUI

struct ChatListView: View {
    @State private var store = ChatStore.shared
    @State private var downloadManager = ModelDownloadManager.shared
    @State private var router = AppRouter.shared
    @State private var searchText = ""
    @State private var path: [Chat] = []

    private var chats: [Chat] {
        _ = store.lastUpdated  // observe mutations
        return store.chats(matching: searchText)
    }

    var body: some View {
        NavigationStack(path: $path) {
            chatList
                .navigationTitle("Chats")
                .navigationDestination(for: Chat.self) { chat in
                    ChatView(chat: chat)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New Chat", systemImage: "square.and.pencil") {
                            startNewChat()
                        }
                        .disabled(!downloadManager.isAvailable)
                    }
                }
        }
        // onChange catches the case where this view is already on screen;
        // onAppear catches a hand-off from another tab (Home), where
        // pendingChat was set before this view existed — onChange wouldn't fire.
        .onChange(of: router.pendingChat) { consumePendingChat() }
        // Hide the bottom tab bar whenever a conversation is open.
        .onChange(of: path) { router.hideTabBar = !path.isEmpty }
        .onChange(of: router.tab) { syncTabBarVisibility() }
        .onAppear {
            consumePendingChat()
            syncTabBarVisibility()
        }
    }

    private func consumePendingChat() {
        guard let chat = router.pendingChat else { return }
        path = [chat]
        router.pendingChat = nil
    }

    private func syncTabBarVisibility() {
        router.hideTabBar = router.tab == .chat && !path.isEmpty
    }

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
            if chats.isEmpty { emptyState }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !downloadManager.isAvailable {
            ContentUnavailableView {
                Label("No model yet", systemImage: "brain")
            } description: {
                Text("Set up a model on the Home tab to start chatting.")
            } actions: {
                Button("Go to Home") { router.tab = .home }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView(
                searchText.isEmpty ? "No chats yet" : "No results",
                systemImage: searchText.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
                description: Text(searchText.isEmpty
                    ? "Tap \(Image(systemName: "square.and.pencil")) to start a conversation."
                    : "Try a different search."))
        }
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
