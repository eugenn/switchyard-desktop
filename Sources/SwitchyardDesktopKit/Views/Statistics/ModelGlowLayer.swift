import SwiftUI

/// The light around the model cards: a soft halo in each model's colour,
/// stronger for a model that carries more of the traffic and strongest, and
/// breathing with the stream, for the one that is working right now.
///
/// Drawn as one canvas behind every card rather than as a blur or a shadow on
/// each: the halo is a few stacked rounded outlines that fade outwards, so a
/// frame costs a handful of strokes and nothing SwiftUI would lay out again.
/// The cards are opaque, so only the light that spills past their edges shows.
package struct ModelGlowLayer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.routingWindowVisible) private var windowVisible

    package struct Glow: Equatable, Identifiable {
        package let id: String
        package let rect: CGRect
        package let cornerRadius: CGFloat
        package let tint: Color
        /// 0...1, from `level(...)`.
        package let level: Double
        /// Whether the halo breathes with the stream instead of holding still.
        package let pulses: Bool
    }

    /// How far the halo reaches past a card. The canvas is this much larger
    /// than the map on every side, so the halo is not cut off at its edge.
    package static let inset: CGFloat = 14

    private static let steps = 8
    private static let stepWidth: CGFloat = 1.75

    package let glows: [Glow]
    package var period: Double = FlowMotion.period

    package init(glows: [Glow], period: Double = FlowMotion.period) {
        self.glows = glows
        self.period = period
    }

    /// How bright a model's halo sits, 0...1. A model that served nothing
    /// gives no light at all: it is a dark port, not a lamp.
    package static func level(
        share: Double, hasTraffic: Bool, isActive: Bool, isSelected: Bool, isFocused: Bool
    ) -> Double {
        guard hasTraffic else { return 0 }
        let base = 0.16 + 0.34 * TokenStream.prominence(share: share)
            + (isActive ? 0.3 : 0) + (isSelected ? 0.12 : 0)
        return min(1, isFocused ? base : base * 0.35)
    }

    private var animates: Bool {
        windowVisible && !reduceMotion && glows.contains(where: \.pulses)
    }

    package var body: some View {
        Group {
            if animates {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    layer(intensity: FlowMotion.pulse(context.date, period: period))
                }
            } else {
                layer(intensity: 0.5)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func layer(intensity: Double) -> some View {
        Canvas { graphics, _ in
            graphics.translateBy(x: Self.inset, y: Self.inset)
            for glow in glows {
                // A pulsing halo swings between two thirds and full strength;
                // one that holds still sits at its level.
                let level = glow.pulses ? glow.level * (0.62 + 0.38 * intensity) : glow.level
                for step in 0..<Self.steps {
                    let falloff = pow(1 - Double(step) / Double(Self.steps), 2.2)
                    let grow = CGFloat(step) * Self.stepWidth + Self.stepWidth / 2
                    let path = RoundedRectangle(cornerRadius: glow.cornerRadius + grow)
                        .path(in: glow.rect.insetBy(dx: -grow, dy: -grow))
                    graphics.stroke(
                        path,
                        with: .color(glow.tint.opacity(0.55 * level * falloff)),
                        lineWidth: Self.stepWidth
                    )
                }
            }
        }
    }
}
