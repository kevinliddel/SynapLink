//
//  RootTabView.swift
//  SynapLink
//
//  App shell. Home and Settings are tabs; the center Chat button opens a
//  conversation as a full-screen overlay that rises from the bottom and fades
//  in, covering the tab bar. Its back button dismisses the overlay, returning
//  to whichever tab (or History) was underneath.
//

import SwiftUI

struct RootTabView: View {
    @State private var router = AppRouter.shared
    @State private var appearance = AppearanceSettings.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            content

            // Floating bar overlays the content; each tab's scroll view adds
            // `.synapTabBarInset()` so nothing scrolls under it.
            SynapTabBar(selection: $router.tab,
                        chatActive: router.presentedChat != nil,
                        onChat: { router.openNewChat() })

            if let chat = router.presentedChat {
                ChatScreen(chat: chat)
                    .zIndex(1)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.38), value: router.presentedChat?.id)
        .preferredColorScheme(appearance.mode.colorScheme)
    }

    @ViewBuilder
    private var content: some View {
        switch router.tab {
        case .home: HomeView()
        case .settings: SettingsView()
        }
    }
}

#Preview {
    RootTabView()
}
