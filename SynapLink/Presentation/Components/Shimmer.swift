//
//  Shimmer.swift
//  SynapLink
//
//  A moving sheen for skeleton placeholders while content loads. Masks the
//  view it's applied to with a travelling gradient, so any shape (a gray
//  capsule, a circle) pulses like a loading skeleton. Apply with
//  `.shimmering()` to placeholder shapes.
//

import SwiftUI

struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = 0
    var duration: Double = 1.4

    func body(content: Content) -> some View {
        content
            .modifier(AnimatedMask(phase: phase).animation(
                .linear(duration: duration).repeatForever(autoreverses: false)))
            .onAppear { phase = 0.8 }
    }

    private struct AnimatedMask: AnimatableModifier {
        var phase: CGFloat = 0

        var animatableData: CGFloat {
            get { phase }
            set { phase = newValue }
        }

        func body(content: Content) -> some View {
            content.mask(GradientMask(phase: phase).scaleEffect(3))
        }
    }

    private struct GradientMask: View {
        let phase: CGFloat

        var body: some View {
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .black.opacity(0.35), location: phase),
                    .init(color: .black, location: phase + 0.1),
                    .init(color: .black.opacity(0.35), location: phase + 0.2)
                ]),
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

extension View {
    /// Apply a loading shimmer when `active` (the skeleton state).
    @ViewBuilder
    func shimmering(_ active: Bool = true) -> some View {
        if active { modifier(Shimmer()) } else { self }
    }
}
