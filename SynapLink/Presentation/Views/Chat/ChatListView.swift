//
//  ChatListView.swift
//  SynapLink
//
//  Chat history: conversation list with search and previews, reached from the
//  Home toolbar's history button. Tapping a row (or New) opens the chat as a
//  full-screen overlay via the router. This view is pushed inside Home's
//  navigation stack, so it has no NavigationStack of its own.
//

import SwiftUI

struct ChatListView: View {
    @State private var store = ChatStore.shared
    @State private var downloadManager = ModelDownloadManager.shared
    @State private var router = AppRouter.shared
    @State private var searchText = ""

    private var chats: [Chat] {
        _ = store.lastUpdated  // observe mutations
        return store.chats(matching: searchText)
    }

    var body: some View {
        List {
            ForEach(chats) { chat in
                Button {
                    router.openChat(chat)
                } label: {
                    ChatRow(chat: chat)
                }
                .buttonStyle(.plain)
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
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Chat", systemImage: "square.and.pencil") {
                    router.openNewChat()
                }
                .disabled(!downloadManager.isAvailable)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !downloadManager.isAvailable {
            ContentUnavailableView {
                Label("No model yet", systemImage: "brain")
            } description: {
                Text("Set up a model on the Home tab to start chatting.")
            }
        } else {
            ContentUnavailableView(
                searchText.isEmpty ? "No chats yet" : "No results",
                systemImage: searchText.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
                description: Text(searchText.isEmpty
                    ? "Start a conversation from the chat button."
                    : "Try a different search."))
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
