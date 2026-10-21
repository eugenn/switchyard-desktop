import SwiftUI

package struct FlowPulseView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.routingWindowVisible) private var windowVisible

    struct Ribbon {
        let id: String
        let shape: Path
        let tint: Color
    }

    static let minimumInterval = 1.0 / 15
    let ribbons: [Ribbon]
    let activity: TokenStream.Activity

    package init(lanes: [TokenStream.Lane], activity: TokenStream.Activity = .idle) {
        self.activity = activity
        ribbons = activity == .idle ? [] : lanes.filter(\.isActive).map {
            Ribbon(id: $0.id, shape: $0.ribbon(), tint: $0.tint)
        }
    }

    var period: Double {
        activity == .thinking ? FlowMotion.restingPeriod : FlowMotion.period
    }

    func animates(windowVisible: Bool, reduceMotion: Bool) -> Bool {
        !ribbons.isEmpty && windowVisible && !reduceMotion
    }

    package var body: some View {
        Group {
            if animates(windowVisible: windowVisible, reduceMotion: reduceMotion) {
                TimelineView(.animation(minimumInterval: Self.minimumInterval)) { context in
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
        // Live traffic swings from nearly dark to bright; a wait keeps the
        // gentler swing so the two never read alike.
        let lively = activity == .streaming
        let fill = lively ? (floor: 0.03, swing: 0.34) : (floor: 0.04, swing: 0.18)
        let edge = lively ? (floor: 0.12, swing: 0.68) : (floor: 0.16, swing: 0.28)
        return Canvas { graphics, _ in
            for ribbon in ribbons {
                graphics.fill(ribbon.shape, with: .color(ribbon.tint.opacity(fill.floor + fill.swing * intensity)))
                graphics.stroke(
                    ribbon.shape, with: .color(ribbon.tint.opacity(edge.floor + edge.swing * intensity)), lineWidth: 1)
            }
        }
    }
}
