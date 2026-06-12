//
//  ChatListView.swift
//  SynapLink
//
//  Home screen: chat history with search, new-chat, model status.
//

import SwiftUI

struct ChatListView: View {
    @State private var store = ChatStore.shared
    @State private var downloadManager = ModelDownloadManager.shared
    @State private var searchText = ""
    @State private var path: [Chat] = []
    @State private var showSettings = false

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
            .onAppear { downloadManager.refreshStates() }
        }
    }

    private var chatList: some View {
        List {
            ForEach(chats) { chat in
                NavigationLink(value: chat) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(chat.title)
                            .lineLimit(1)
                        Text(chat.updatedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                let current = chats
                for offset in offsets {
                    store.deleteChat(id: current[offset].id)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search chats")
        .overlay {
            if chats.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No chats yet" : "No results",
                    systemImage: searchText.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
                    description: Text(searchText.isEmpty ? "Tap New Chat to start." : "Try a different search."))
            }
        }
    }

    private var firstRunPrompt: some View {
        ContentUnavailableView {
            Label("Download a model to start", systemImage: "arrow.down.circle")
        } description: {
            Text("SynapLink runs entirely on your device. Download a model once and chat fully offline.")
        } actions: {
            Button("Open Model Library") { showSettings = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private func startNewChat() {
        if let chat = ChatSession.shared.startNewChat() {
            path.append(chat)
        }
    }
}

#Preview {
    ChatListView()
}
