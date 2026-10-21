import Foundation
import Testing
@testable import SwitchyardDesktopKit

@MainActor
private final class Counter {
    var beats = 0
}

@MainActor
@Test func signalDefaultsToFiveMinutes() {
    #expect(RecalculationSignal().interval == .seconds(300))
    #expect(RecalculationSignal.defaultInterval == .seconds(300))
}

@MainActor
@Test func sendReachesEverySubscriberInOrderBeforeReturning() async {
    let signal = RecalculationSignal()
    let first = Counter()
    let second = Counter()
    var order: [String] = []
    signal.subscribe(first) {
        first.beats += 1
        order.append("first")
    }
    signal.subscribe(second) {
        second.beats += 1
        order.append("second")
    }

    await signal.send()

    #expect(first.beats == 1)
    #expect(second.beats == 1)
    #expect(order == ["first", "second"])
    #expect(signal.lastSignal != nil)
    signal.unsubscribe(first)
    signal.unsubscribe(second)
}

@MainActor
@Test func aReleasedOrUnsubscribedOwnerNoLongerHearsTheSignal() async {
    let signal = RecalculationSignal()
    let kept = Counter()
    let left = Counter()
    var released: Counter? = Counter()
    var releasedBeats = 0
    signal.subscribe(kept) { kept.beats += 1 }
    signal.subscribe(left) { left.beats += 1 }
    signal.subscribe(released!) { releasedBeats += 1 }

    released = nil
    signal.unsubscribe(left)
    await signal.send()

    #expect(kept.beats == 1)
    #expect(left.beats == 0)
    #expect(releasedBeats == 0)
    signal.unsubscribe(kept)
}

@MainActor
@Test func signalBeatsOnItsIntervalAndFollowsAChange() async throws {
    let signal = RecalculationSignal(interval: .seconds(3_600))
    let counter = Counter()
    signal.subscribe(counter) { counter.beats += 1 }
    defer { signal.unsubscribe(counter) }

    try await Task.sleep(for: .milliseconds(100))
    #expect(counter.beats == 0)

    signal.interval = .milliseconds(20)
    // Generous: other tests can hold the main actor for seconds at a time.
    let deadline = Date().addingTimeInterval(30)
    while counter.beats < 2, Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(counter.beats >= 2)
}

@MainActor
@Test func monitorsShareTheirModelsSignal() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = WizardModel(
        sessionStore: ActiveRoutingSessionStore(fileURL: directory.appendingPathComponent("session.json")),
        restoreSavedSetup: false
    )
    let log = RoutingLogReader(url: directory.appendingPathComponent("routing.jsonl"))
    let first = RoutingMonitor(model: model, logReader: log)
    let second = RoutingMonitor(model: model, logReader: log)

    #expect(first.recalculationSignal === model.recalculationSignal)
    #expect(second.recalculationSignal === model.recalculationSignal)
}

@MainActor
@Test func aBeatWithTheRouterStoppedLeavesTheCostAlone() async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = WizardModel(
        sessionStore: ActiveRoutingSessionStore(fileURL: directory.appendingPathComponent("session.json")),
        restoreSavedSetup: false
    )
    let monitor = RoutingMonitor(
        model: model, logReader: RoutingLogReader(url: directory.appendingPathComponent("routing.jsonl")))

    await model.recalculationSignal.send()

    #expect(monitor.lastCostRecalculation == nil)
    #expect(monitor.lastRefresh == nil)
}
