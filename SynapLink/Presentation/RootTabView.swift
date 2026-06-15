//
//  RootTabView.swift
//  SynapLink
//
//  The app shell. Instead of the system TabView bar, the selected tab's
//  content fills the screen and a custom SynapTabBar is added as a bottom
//  safe-area inset (styled like the chat footer). The bar is omitted while a
//  conversation is open, so the chat input bar owns the bottom edge.
//

import SwiftUI

struct RootTabView: View {
    @State private var router = AppRouter.shared

    var body: some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !router.hideTabBar {
                    SynapTabBar(selection: $router.tab)
                        .transition(.move(edge: .bottom))
                }
            }
            .animation(.snappy(duration: 0.2), value: router.hideTabBar)
    }

    @ViewBuilder
    private var content: some View {
        switch router.tab {
        case .home: HomeView()
        case .chat: ChatListView()
        case .settings: SettingsView()
        }
    }
}

#Preview {
    RootTabView()
}
