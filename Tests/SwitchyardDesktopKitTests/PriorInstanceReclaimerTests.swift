import Foundation
import Testing
@testable import SwitchyardDesktopKit

private final class FakeRunningInstanceInspector: RunningInstanceInspecting, @unchecked Sendable {
    var instances: [Int32] = []
    var terminatedByRequest: Set<Int32> = []
    var terminatedByForce: Set<Int32> = []
    /// PIDs that ignore a plain request and only die once forced.
    var ignoresRequest: Set<Int32> = []
    private var alive: Set<Int32>

    init(alive: Set<Int32>) {
        self.alive = alive
    }

    func otherInstances(executablePath: String, excluding pid: Int32) -> [Int32] {
        instances.filter { $0 != pid }
    }

    func requestTermination(_ pid: Int32) {
        terminatedByRequest.insert(pid)
        if !ignoresRequest.contains(pid) { alive.remove(pid) }
    }

    func forceTermination(_ pid: Int32) {
        terminatedByForce.insert(pid)
        alive.remove(pid)
    }

    func isAlive(_ pid: Int32) -> Bool {
        alive.contains(pid)
    }
}

@Test func reclaimStopsAnotherInstanceOfTheSameExecutable() {
    let inspector = FakeRunningInstanceInspector(alive: [42])
    inspector.instances = [42]
    let reclaimer = PriorInstanceReclaimer(
        inspector: inspector, terminationTimeout: 0.2, killTimeout: 0.2, pollInterval: 0.01
    )

    let stopped = reclaimer.reclaim(executablePath: "/tmp/switchyard-desktopApp", excluding: 7)

    #expect(stopped == [42])
    #expect(inspector.terminatedByRequest == [42])
    #expect(inspector.terminatedByForce.isEmpty)
}

@Test func reclaimForcesAnInstanceThatIgnoresTermination() {
    let inspector = FakeRunningInstanceInspector(alive: [42])
    inspector.instances = [42]
    inspector.ignoresRequest = [42]
    let reclaimer = PriorInstanceReclaimer(
        inspector: inspector, terminationTimeout: 0.05, killTimeout: 0.2, pollInterval: 0.01
    )

    let stopped = reclaimer.reclaim(executablePath: "/tmp/switchyard-desktopApp", excluding: 7)

    #expect(stopped == [42])
    #expect(inspector.terminatedByRequest == [42])
    #expect(inspector.terminatedByForce == [42])
}

@Test func reclaimIgnoresItsOwnProcess() {
    let inspector = FakeRunningInstanceInspector(alive: [7])
    inspector.instances = [7]
    let reclaimer = PriorInstanceReclaimer(inspector: inspector)

    let stopped = reclaimer.reclaim(executablePath: "/tmp/switchyard-desktopApp", excluding: 7)

    #expect(stopped.isEmpty)
    #expect(inspector.terminatedByRequest.isEmpty)
}
