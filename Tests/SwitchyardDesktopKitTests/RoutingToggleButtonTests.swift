import Foundation
import Testing
@testable import SwitchyardDesktopKit

@Suite("Routing toggle button")
struct RoutingToggleButtonTests {
    @Test("A settled route reads as idle or running")
    func settledPhases() {
        #expect(RoutingPhase.resolve(held: nil, isBusy: false, isStopping: false, isRouting: false) == .idle)
        #expect(RoutingPhase.resolve(held: nil, isBusy: false, isStopping: false, isRouting: true) == .running)
    }

    @Test("Work in flight reads as the direction it is going")
    func busyPhases() {
        #expect(RoutingPhase.resolve(held: nil, isBusy: true, isStopping: false, isRouting: false) == .starting)
        // The tail of a start already has a session, and is still a start.
        #expect(RoutingPhase.resolve(held: nil, isBusy: true, isStopping: false, isRouting: true) == .starting)
        #expect(RoutingPhase.resolve(held: nil, isBusy: true, isStopping: true, isRouting: true) == .stopping)
    }

    @Test("A held phase outlasts the model finishing")
    func heldPhaseWins() {
        #expect(RoutingPhase.resolve(held: .starting, isBusy: false, isStopping: false, isRouting: true) == .starting)
        #expect(RoutingPhase.resolve(held: .stopping, isBusy: false, isStopping: false, isRouting: false) == .stopping)
    }

    @Test("Only a settled route takes a tap")
    func acceptsTap() {
        #expect(RoutingPhase.idle.acceptsTap)
        #expect(RoutingPhase.running.acceptsTap)
        #expect(!RoutingPhase.starting.acceptsTap)
        #expect(!RoutingPhase.stopping.acceptsTap)
    }
}
