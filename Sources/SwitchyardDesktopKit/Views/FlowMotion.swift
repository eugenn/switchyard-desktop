import SwiftUI

/// Motion shared by both flow maps. Every one of these is driven by the clock
/// rather than by a repeating animation, so a lane that stops being the active
/// one simply stops drawing instead of finishing a cycle on its own.
///
/// They also all avoid changing anything SwiftUI would answer with a layout
/// pass. A view that resizes itself thirty times a second re-measures the
/// window it sits in just as often, and the flow maps are large enough that
/// doing so costs more than everything else the app does put together.
package enum FlowMotion {
    /// One rise and fall in brightness while tokens move, shared by the path
    /// and its node. Short enough that the eye reads it as a flicker.
    package static let period: Double = 1.1

    /// The slower breath everything wears while the map is alive but nothing
    /// is moving on it. Kept well clear of `period` so a wait never reads as
    /// traffic that happens to be quiet.
    package static let restingPeriod: Double = 3.6

    /// Whether `period` is the pulse of live traffic rather than a wait.
    package static func isLive(period: Double) -> Bool { period < restingPeriod }

    /// How far through its cycle the clock is, 0..<1.
    package static func phase(_ date: Date, period: Double = period) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
    }

    /// 0...1...0, with no visible jump when the cycle repeats.
    package static func intensity(_ date: Date, period: Double = period) -> Double {
        0.5 - 0.5 * cos(phase(date, period: period) * 2 * .pi)
    }

    /// Brightness for a pulse of `period`, 0...1. A wait breathes smoothly; live
    /// traffic flickers: a second, faster rise and fall that never lines up
    /// with the first is laid over it, so the light stutters instead of
    /// swelling evenly. Everything that shares a period shares the flicker.
    package static func pulse(_ date: Date, period: Double = period) -> Double {
        let base = intensity(date, period: period)
        guard isLive(period: period) else { return base }
        return 0.6 * base + 0.4 * intensity(date, period: period * 0.37)
    }
}

/// The shimmer a role's card wears while its model is working: the rim and
/// the face breathe with the stream, and a soft sheen sweeps across the card
/// once a cycle, so a working role reads as busy from across the window.
///
/// Drawn over the card and sized by it, so a frame changes the colours of
/// two layers and nothing SwiftUI would have to lay out again.
package struct WorkingShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.routingWindowVisible) private var windowVisible

    package let tint: Color
    package let isWorking: Bool
    package var cornerRadius: CGFloat
    /// The stream's own pulse while tokens move; the slower resting breath
    /// while the model is only thinking, so the two never read alike.
    package var period: Double

    package init(tint: Color, isWorking: Bool, cornerRadius: CGFloat, period: Double = FlowMotion.period) {
        self.tint = tint
        self.isWorking = isWorking
        self.cornerRadius = cornerRadius
        self.period = period
    }

    package func body(content: Content) -> some View {
        content.overlay {
            if isWorking {
                if reduceMotion || !windowVisible {
                    shimmer(intensity: 0.5, sweep: nil)
                } else {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                        shimmer(
                            intensity: FlowMotion.pulse(context.date, period: period),
                            // The sheen crosses at half the breath's pace, so
                            // it reads as a glint rather than a scanning bar.
                            sweep: FlowMotion.phase(context.date, period: period * 2)
                        )
                    }
                }
            }
        }
    }

    private func shimmer(intensity: Double, sweep: Double?) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        // Live traffic swings wider than a wait, so a working card stands out.
        let lively = FlowMotion.isLive(period: period)
        return ZStack {
            shape.fill(tint.opacity(0.03 + (lively ? 0.13 : 0.07) * intensity))
            if let sweep {
                // Starts and ends off the card, so the glint slides in from
                // the edge the stream arrives at and out the other side.
                let center = -0.35 + 1.7 * sweep
                shape.fill(LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: tint.opacity(0.16), location: 0.5),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: UnitPoint(x: center - 0.3, y: 0.2),
                    endPoint: UnitPoint(x: center + 0.3, y: 0.8)
                ))
            }
            shape.strokeBorder(tint.opacity((lively ? 0.15 : 0.3) + (lively ? 0.85 : 0.5) * intensity), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Marks the card of the role whose model is working right now.
    package func workingShimmer(
        tint: Color, isWorking: Bool, cornerRadius: CGFloat, period: Double = FlowMotion.period
    ) -> some View {
        modifier(WorkingShimmer(tint: tint, isWorking: isWorking, cornerRadius: cornerRadius, period: period))
    }
}

/// The "something is flowing right now" chip a flow map puts in its header.
///
/// Only the dot moves, so only the dot is on a timeline: with the whole chip
/// inside one, every frame re-measured its text and the capsule behind it.
package struct LiveBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.routingWindowVisible) private var windowVisible

    package let tint: Color
    package let text: String
    package var font: Font = RouterTheme.mono(10)
    package var period: Double = FlowMotion.period
    /// Whether this chip's own dot blinks. The one thing on the map that
    /// moves for a wait is the served role's shimmering card; this chip is
    /// only naming that wait, so its dot holds still rather than blinking too.
    package var blinks: Bool = true
    /// What the chip means when it does not mean live traffic.
    package var accessibilityText: String?

    package init(
        tint: Color, text: String, font: Font = RouterTheme.mono(10), period: Double = FlowMotion.period,
        blinks: Bool = true, accessibilityText: String? = nil
    ) {
        self.tint = tint
        self.text = text
        self.font = font
        self.period = period
        self.blinks = blinks
        self.accessibilityText = accessibilityText
    }

    package var body: some View {
        HStack(spacing: 5) {
            dot
            Text(text)
                .font(font)
                .foregroundStyle(RouterTheme.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.1), in: Capsule())
        .fixedSize()
        .accessibilityLabel(accessibilityText ?? "Live traffic on \(text)")
    }

    /// Sized from the outside, so a frame changes a fill and nothing else.
    private var dot: some View {
        let paused = reduceMotion || !blinks || !windowVisible
        return TimelineView(.animation(minimumInterval: 1 / 15, paused: paused)) { context in
            let intensity = paused ? 0.5 : FlowMotion.pulse(context.date, period: period)
            Circle().fill(tint.opacity(0.45 + 0.55 * intensity))
        }
        .frame(width: 6, height: 6)
    }
}
