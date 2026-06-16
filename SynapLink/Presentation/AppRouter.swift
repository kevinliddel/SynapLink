//
//  AppRouter.swift
//  SynapLink
//
//  Drives navigation. Home and Settings are the two tabs. Chat is not a tab —
//  it's a full-screen conversation presented OVER the current tab (so its back
//  button returns to wherever you came from: Home or Settings, or History).
//

import Foundation
import Observation

@MainActor
@Observable
final class AppRouter {

    static let shared = AppRouter()

    enum Tab: Hashable {
        case home, settings
    }

    var tab: Tab = .home

    /// Non-nil while a conversation is shown as a full-screen overlay.
    var presentedChat: Chat?

    private init() {}

    /// Open a fresh conversation (the center tab-bar button).
    func openNewChat() {
        guard let chat = ChatSession.shared.startNewChat() else { return }
        presentedChat = chat
    }

    /// Open an existing conversation (from History).
    func openChat(_ chat: Chat) {
        presentedChat = chat
    }

    func closeChat() {
        presentedChat = nil
    }
}
