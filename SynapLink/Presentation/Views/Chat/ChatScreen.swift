//
//  ChatScreen.swift
//  SynapLink
//
//  Full-screen wrapper around ChatView for the conversation overlay. Provides
//  the back button that dismisses the overlay (returning to the previous tab
//  or History) — this is not a NavigationStack push, so the back chevron is
//  ours, not the system's.
//

import SwiftUI

struct ChatScreen: View {
    let chat: Chat

    @State private var router = AppRouter.shared

    var body: some View {
        NavigationStack {
            ChatView(chat: chat)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            router.closeChat()
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.body.weight(.semibold))
                        }
                        .accessibilityLabel("Close chat")
                    }
                }
        }
        .background(Color(.systemBackground))
    }
}
