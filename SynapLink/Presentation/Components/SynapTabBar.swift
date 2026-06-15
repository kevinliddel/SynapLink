//
//  SynapTabBar.swift
//  SynapLink
//
//  Custom bottom tab bar matching the chat input footer's look. Home and
//  Settings are icon+label tabs; the center Chat button is a raised circle
//  (icon-only) that pokes above the bar and opens a conversation rather than
//  switching tabs. Tapping any item plays a small symbol "bounce".
//

import SwiftUI

struct SynapTabBar: View {
    @Binding var selection: AppRouter.Tab
    var chatActive: Bool
    var onChat: () -> Void

    @State private var bumps: [AppRouter.Tab: Int] = [:]
    @State private var chatBump = 0

    private let circleSize: CGFloat = 65
    private var poke: CGFloat { circleSize * 0.45 }

    /// Height the bar occupies ABOVE the bottom safe area. Scroll content uses
    /// this (via `.synapTabBarInset()`) so nothing hides behind the bar —
    /// `.safeAreaInset` on the bar itself doesn't reach scroll views nested in
    /// each tab's NavigationStack, so we inset the scroll views directly.
    static let reservedHeight: CGFloat = 88

    var body: some View {
        ZStack(alignment: .top) {
            card
            chatButton  // raised, overlaps the card's top edge
        }
    }

    private var card: some View {
        HStack(spacing: 0) {
            sideButton(.home, title: "Home", icon: "house")
            Spacer(minLength: circleSize)
            sideButton(.settings, title: "Settings", icon: "gearshape")
        }
        .padding(.horizontal, 30)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 40, topTrailingRadius: 40, style: .continuous)
                .fill(.bar)
                .ignoresSafeArea(edges: .bottom)
        }
        .padding(.top, poke)
    }

    private func sideButton(_ tab: AppRouter.Tab, title: String, icon: String) -> some View {
        let selected = selection == tab && !chatActive
        return Button {
            bumps[tab, default: 0] += 1
            withAnimation(.snappy(duration: 0.2)) { selection = tab }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .symbolVariant(selected ? .fill : .none)
                    .symbolEffect(.bounce, value: bumps[tab])
                Text(title)
                    .font(.caption2.weight(selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var chatButton: some View {
        Button {
            chatBump += 1
            onChat()
        } label: {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.bounce, value: chatBump)
                .frame(width: circleSize, height: circleSize)
                .background(Circle().fill(Color.accentColor.gradient))
                .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 4))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New chat")
    }
}

extension View {
    /// Reserve bottom space for the floating tab bar so scroll content clears
    /// it. Apply to a scrollable view (ScrollView / List / Form) on any screen
    /// the tab bar overlays.
    func synapTabBarInset() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: SynapTabBar.reservedHeight)
        }
    }
}

#Preview {
    ZStack(alignment: .bottom) {
        Color(.systemGroupedBackground).ignoresSafeArea()
        SynapTabBar(selection: .constant(.home), chatActive: false, onChat: {})
    }
}
