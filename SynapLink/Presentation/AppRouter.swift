//
//  AppRouter.swift
//  SynapLink
//
//  Drives the bottom tab bar and the few cross-tab jumps (Home's actions open
//  a conversation that lives in the Chat tab).
//

import Foundation
import Observation

@MainActor
@Observable
final class AppRouter {

    static let shared = AppRouter()

    enum Tab: Hashable {
        case home, chat, settings
    }

    var tab: Tab = .home

    /// Hidden while a conversation is open so the chat input bar owns the
    /// bottom edge. Driven by the Chat tab's navigation depth.
    var hideTabBar = false

    /// Set by Home to hand a chat to the Chat tab, which pushes it and clears this.
    var pendingChat: Chat?

    private init() {}

    /// Switch to the Chat tab and open `chat` there.
    func openChat(_ chat: Chat) {
        pendingChat = chat
        tab = .chat
    }
}
