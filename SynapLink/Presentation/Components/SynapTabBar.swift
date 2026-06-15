//
//  SynapTabBar.swift
//  SynapLink
//
//  Custom bottom tab bar matching the chat input footer's look: a rounded-top
//  `.bar` card that runs under the home indicator. Home and Settings are
//  icon+label; Chat is a raised circular button (icon-only) that pokes ~40%
//  above the bar's top edge. Tapping any item plays a small symbol "bounce".
//  Hidden entirely inside a conversation.
//

import SwiftUI

struct SynapTabBar: View {
    @Binding var selection: AppRouter.Tab

    /// Per-tab tap counters drive the `.bounce` symbol effect (a re-tap bumps too).
    @State private var bumps: [AppRouter.Tab: Int] = [:]

    private let circleSize: CGFloat = 65
    private var poke: CGFloat { circleSize * 0.45 }  // how much the circle clears the card top

    var body: some View {
        ZStack(alignment: .top) {
            card
            chatButton  // raised, overlaps the card's top edge
        }
    }

    // MARK: - Card (Home · gap · Settings)

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
        .padding(.top, poke)  // push the card down so the circle has room to poke above it
    }

    private func sideButton(_ tab: AppRouter.Tab, title: String, icon: String) -> some View {
        let selected = selection == tab
        return Button {
            select(tab)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .symbolVariant(selected ? .fill : .none)
                    .symbolEffect(.bounce, value: bumps[tab])
                Text(title)
                    .font(.caption2.weight(selected ? .semibold : .regular))
            }
            .foregroundStyle(
                selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)
            )
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Chat (raised circle, icon-only)

    private var chatButton: some View {
        let selected = selection == .chat
        return Button {
            select(.chat)
        } label: {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.bounce, value: bumps[.chat])
                .frame(width: circleSize, height: circleSize)
                // Always accent — it's the hero/primary action; selection is
                // conveyed by a subtle ring rather than graying it out.
                .background(Circle().fill(Color.accentColor.gradient))
                .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 4))
                .overlay(
                    Circle().strokeBorder(
                        Color.accentColor.opacity(selected ? 0.9 : 0), lineWidth: 2
                    )
                    .padding(-3)
                )
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Chat")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func select(_ tab: AppRouter.Tab) {
        bumps[tab, default: 0] += 1
        withAnimation(.snappy(duration: 0.2)) { selection = tab }
    }
}

#Preview {
    ZStack(alignment: .bottom) {
        Color(.systemGroupedBackground).ignoresSafeArea()
        SynapTabBar(selection: .constant(.chat))
    }
}
