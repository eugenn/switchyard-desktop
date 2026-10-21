import SwiftUI
import Testing
@testable import SwitchyardDesktopKit

@MainActor
@Suite("Active flow pulse")
struct FlowPulseTests {
    private func lane(id: String, active: Bool) -> TokenStream.Lane {
        TokenStream.Lane(
            id: id,
            curve: TokenStream.Curve(from: .zero, to: CGPoint(x: 180, y: 60)),
            tint: .green, share: 0.5, spread: 5, isActive: active
        )
    }

    @Test("Only active lanes pulse", arguments: [TokenStream.Activity.streaming, .thinking])
    func activeLanes(activity: TokenStream.Activity) {
        let active = lane(id: "current", active: true)
        let view = FlowPulseView(lanes: [lane(id: "quiet", active: false), active], activity: activity)
        #expect(view.ribbons.map(\.id) == ["current"])
        #expect(view.ribbons.first?.shape == active.ribbon())
        #expect(view.animates(windowVisible: true, reduceMotion: false))
    }

    @Test("Idle and empty flows stay still")
    func idleFlows() {
        let idle = FlowPulseView(lanes: [lane(id: "current", active: true)], activity: .idle)
        let empty = FlowPulseView(lanes: [lane(id: "quiet", active: false)], activity: .streaming)
        #expect(idle.ribbons.isEmpty)
        #expect(empty.ribbons.isEmpty)
        #expect(!idle.animates(windowVisible: true, reduceMotion: false))
        #expect(!empty.animates(windowVisible: true, reduceMotion: false))
    }

    @Test("A tapered incoming path pulses within its existing bed")
    func taperedGeometry() {
        let incoming = TokenStream.Lane(
            id: "incoming", curve: TokenStream.Curve(from: .zero, to: CGPoint(x: 180, y: 0)),
            tint: .green, share: 1, spread: 7, endSpread: 2, isActive: true
        )
        let view = FlowPulseView(lanes: [incoming], activity: .streaming)
        #expect(view.ribbons.first?.shape == incoming.ribbon(endWidth: 4))
    }

    @Test("Hidden windows and Reduce Motion do not run a timeline")
    func suspendedAnimation() {
        let view = FlowPulseView(lanes: [lane(id: "current", active: true)], activity: .streaming)
        #expect(!view.animates(windowVisible: false, reduceMotion: false))
        #expect(!view.animates(windowVisible: true, reduceMotion: true))
        #expect(!view.animates(windowVisible: false, reduceMotion: true))
    }

    @Test("Thinking pulses more slowly and flow rendering is capped at 15 fps")
    func cadence() {
        let lanes = [lane(id: "current", active: true)]
        #expect(FlowPulseView(lanes: lanes, activity: .streaming).period == FlowMotion.period)
        #expect(FlowPulseView(lanes: lanes, activity: .thinking).period == FlowMotion.restingPeriod)
        #expect(FlowMotion.restingPeriod > FlowMotion.period)
        #expect(FlowPulseView.minimumInterval >= 1.0 / 15)
    }

    @Test("Live traffic flickers across the whole range; a wait breathes smoothly")
    func flicker() {
        let dates = (0..<400).map { Date(timeIntervalSinceReferenceDate: Double($0) * 0.05) }
        let live = dates.map { FlowMotion.pulse($0, period: FlowMotion.period) }
        let wait = dates.map { FlowMotion.pulse($0, period: FlowMotion.restingPeriod) }
        #expect(live.allSatisfy { (0...1).contains($0) })
        #expect(live.max()! - live.min()! > 0.8)
        #expect(wait == dates.map { FlowMotion.intensity($0, period: FlowMotion.restingPeriod) })
        #expect(FlowMotion.isLive(period: FlowMotion.period))
        #expect(!FlowMotion.isLive(period: FlowMotion.restingPeriod))
    }
}
