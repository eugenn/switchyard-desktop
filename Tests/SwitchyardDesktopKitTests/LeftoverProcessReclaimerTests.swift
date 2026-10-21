import Foundation
import Testing
@testable import SwitchyardDesktopKit

/// A process table this test controls: who is alive, what each one runs, which
/// of them ignores a signal, and who listens on a port.
private final class FakeInspector: ProcessInspecting, @unchecked Sendable {
    struct Entry {
        var path: String
        var ignoresTerm = false
        var ignoresKill = false
    }

    private let lock = NSLock()
    private var alive: [Int32: Entry]
    private var listeners: [Int: [Int32]]
    private var sent: [(pid: Int32, signal: String)] = []

    init(alive: [Int32: Entry] = [:], listeners: [Int: [Int32]] = [:]) {
        self.alive = alive
        self.listeners = listeners
    }

    var signals: [(pid: Int32, signal: String)] {
        lock.withLock { sent }
    }

    func signalled(_ pid: Int32) -> [String] {
        lock.withLock { sent.filter { $0.pid == pid }.map(\.signal) }
    }

    func isAlive(_ pid: Int32) -> Bool {
        lock.withLock { alive[pid] != nil }
    }

    func executablePath(of pid: Int32) -> String? {
        lock.withLock { alive[pid]?.path }
    }

    func listeningPIDs(port: Int) -> [Int32] {
        lock.withLock { (listeners[port] ?? []).filter { alive[$0] != nil } }
    }

    func terminate(_ pid: Int32) {
        lock.withLock {
            sent.append((pid, "TERM"))
            if alive[pid]?.ignoresTerm == false { alive[pid] = nil }
        }
    }

    func forceKill(_ pid: Int32) {
        lock.withLock {
            sent.append((pid, "KILL"))
            if alive[pid]?.ignoresKill == false { alive[pid] = nil }
        }
    }
}

private func reclaimer(_ inspector: FakeInspector) -> LeftoverProcessReclaimer {
    LeftoverProcessReclaimer(
        inspector: inspector,
        terminationTimeout: .milliseconds(100),
        killTimeout: .milliseconds(100),
        pollInterval: .milliseconds(5)
    )
}

private func record(
    _ pid: Int32,
    path: String = "/opt/switchyard-desktop/switchyard-server",
    port: Int = 4100,
    name: String = "switchyard-server"
) -> ManagedProcessRecord {
    ManagedProcessRecord(
        name: name, pid: pid, port: port, executablePath: path, startedAt: Date()
    )
}

@Test func aRecordedChildStillRunningIsStoppedAndItsRecordCleared() async {
    let path = "/opt/switchyard-desktop/switchyard-server"
    let inspector = FakeInspector(alive: [4242: .init(path: path)])

    let outcomes = await reclaimer(inspector).reclaim(records: [record(4242, path: path)])

    #expect(outcomes.map(\.outcome) == [.reclaimed(name: "switchyard-server", pid: 4242, forced: false)])
    #expect(outcomes[0].outcome.clearsRecord)
    #expect(inspector.signalled(4242) == ["TERM"])
    #expect(!inspector.isAlive(4242))
}

@Test func aServerThatIgnoresTerminationIsKilled() async {
    let path = "/opt/switchyard-desktop/switchyard-server"
    let inspector = FakeInspector(alive: [7: .init(path: path, ignoresTerm: true)])

    let outcomes = await reclaimer(inspector).reclaim(records: [record(7, path: path)])

    #expect(outcomes.map(\.outcome) == [.reclaimed(name: "switchyard-server", pid: 7, forced: true)])
    #expect(inspector.signalled(7) == ["TERM", "KILL"])
}

/// Killing a process is only safe while the PID still belongs to the recorded
/// executable; after a reboot that number is somebody else's.
@Test func aRecycledPIDIsReportedButNeverSignalled() async {
    let inspector = FakeInspector(alive: [99: .init(path: "/usr/bin/vim")])

    let outcomes = await reclaimer(inspector).reclaim(
        records: [record(99, path: "/opt/switchyard-desktop/switchyard-server")]
    )

    #expect(outcomes.map(\.outcome) == [.reused(pid: 99)])
    #expect(outcomes[0].outcome.clearsRecord)
    #expect(inspector.signals.isEmpty)
    #expect(inspector.isAlive(99))
}

@Test func aRecordForAProcessThatAlreadyExitedIsDropped() async {
    let inspector = FakeInspector()

    let outcomes = await reclaimer(inspector).reclaim(records: [record(1234)])

    #expect(outcomes.map(\.outcome) == [.vanished(pid: 1234)])
    #expect(inspector.signals.isEmpty)
}

@Test func theProcessThisRunStartedIsNeverReclaimed() async {
    let path = "/opt/switchyard-desktop/switchyard-server"
    let inspector = FakeInspector(alive: [55: .init(path: path)], listeners: [4100: [55]])
    let subject = reclaimer(inspector)

    let recorded = await subject.reclaim(records: [record(55, path: path)], excluding: [55])
    let byPort = await subject.reclaimPort(
        4100, name: "switchyard-server", ownedExecutables: [path], excluding: [55]
    )

    #expect(recorded.isEmpty)
    #expect(byPort.isEmpty)
    #expect(inspector.signals.isEmpty)
}

@Test func aPortHeldByThisAppsOwnExecutableIsFreed() async {
    let path = "/opt/switchyard-desktop/switchyard-server"
    let inspector = FakeInspector(alive: [321: .init(path: path)], listeners: [4100: [321]])

    let outcomes = await reclaimer(inspector).reclaimPort(
        4100, name: "switchyard-server", ownedExecutables: ["/opt/switchyard-desktop/./switchyard-server"]
    )

    #expect(outcomes == [.reclaimed(name: "switchyard-server", pid: 321, forced: false)])
    #expect(!inspector.isAlive(321))
}

/// Freeing 4100 by killing whatever holds it would make this app a hazard to
/// every other program on the machine.
@Test func aPortHeldByAnotherProgramIsReportedNotKilled() async {
    let inspector = FakeInspector(
        alive: [808: .init(path: "/usr/local/bin/some-server")], listeners: [4100: [808]]
    )

    let outcomes = await reclaimer(inspector).reclaimPort(
        4100, name: "switchyard-server", ownedExecutables: ["/opt/switchyard-desktop/switchyard-server"]
    )

    #expect(outcomes == [.foreign(port: 4100, pid: 808, path: "/usr/local/bin/some-server")])
    #expect(inspector.signals.isEmpty)
    #expect(inspector.isAlive(808))

    var report = LeftoverReclaimReport()
    report.add(outcomes[0], port: 4100)
    #expect(report.reclaimed.isEmpty)
    #expect(report.blocked.first?.contains("some-server") == true)
    #expect(report.blocked.first?.contains("did not start") == true)
}

@Test func aProcessThatSurvivesBothSignalsIsReportedAsABlocker() async {
    let path = "/opt/switchyard-desktop/switchyard-server"
    let inspector = FakeInspector(
        alive: [11: .init(path: path, ignoresTerm: true, ignoresKill: true)]
    )

    let outcomes = await reclaimer(inspector).reclaim(records: [record(11, path: path)])

    #expect(outcomes.map(\.outcome) == [.survived(name: "switchyard-server", pid: 11)])
    // The record stays: something is still holding the port.
    #expect(!outcomes[0].outcome.clearsRecord)

    var report = LeftoverReclaimReport()
    report.add(outcomes[0].outcome, port: 4100)
    #expect(report.blocked.first?.contains("pid 11") == true)
    #expect(!report.freedSomething)
}

@Test func aFreedPortIsDescribedInTheWordsTheUserReads() async {
    var report = LeftoverReclaimReport()
    report.add(.reclaimed(name: "LiteLLM", pid: 18570, forced: true), port: 4101)

    #expect(report.freedSomething)
    #expect(report.reclaimed.first?.contains("LiteLLM (pid 18570)") == true)
    #expect(report.reclaimed.first?.contains("port 4101 is free again") == true)
}

@Test func waitingForAPortGivesUpRatherThanHangingForever() async {
    let subject = reclaimer(FakeInspector())

    let cleared = await subject.waitForPortToClear(
        host: "127.0.0.1", port: 4100, timeout: .milliseconds(60), isAvailable: { _, _ in false }
    )
    let free = await subject.waitForPortToClear(
        host: "127.0.0.1", port: 4100, timeout: .milliseconds(60), isAvailable: { _, _ in true }
    )

    #expect(!cleared)
    #expect(free)
}

@Test func theHolderOfAPortIsNamedForTheReadinessMessage() {
    let inspector = FakeInspector(
        alive: [18590: .init(path: "/opt/switchyard-desktop/switchyard-server")],
        listeners: [4100: [18590]]
    )

    let holder = reclaimer(inspector).holder(ofPort: 4100)

    #expect(holder?.pid == 18590)
    #expect(RoutingReadinessChecker.holderSuffix(holder) == "— held by switchyard-server (pid 18590)".withLeadingSpace)
    #expect(RoutingReadinessChecker.holderSuffix(nil).isEmpty)
}

private extension String {
    var withLeadingSpace: String { " " + self }
}

// MARK: - The manager's own use of the reclaimer

@MainActor
private final class FakeRegistry: ManagedProcessRecording {
    private(set) var stored: [ManagedProcessRecord]

    init(_ stored: [ManagedProcessRecord] = []) {
        self.stored = stored
    }

    func records() -> [ManagedProcessRecord] { stored }

    func record(_ record: ManagedProcessRecord) {
        stored.removeAll { $0.pid == record.pid }
        stored.append(record)
    }

    func forget(pid: Int32) {
        stored.removeAll { $0.pid == pid }
    }
}

/// The state a crash leaves: a record on disk and a server still holding 4100.
@MainActor
@Test func theManagerFreesAPortHeldBySomethingAnEarlierRunStarted() async {
    let path = "/opt/switchyard-desktop/switchyard-server"
    let registry = FakeRegistry([record(6001, path: path)])
    let inspector = FakeInspector(alive: [6001: .init(path: path)], listeners: [4100: [6001]])
    let manager = SwitchyardProcessManager(registry: registry, reclaimer: reclaimer(inspector))

    let report = await manager.reclaimLeftovers(port: 4100, binaryPath: URL(fileURLWithPath: path))

    #expect(report.freedSomething)
    #expect(report.blocked.isEmpty)
    #expect(!inspector.isAlive(6001))
    #expect(registry.records().isEmpty)
}

@MainActor
@Test func aStaleRecordIsClearedWithoutTouchingAnything() async {
    let registry = FakeRegistry([record(6002)])
    let inspector = FakeInspector()
    let manager = SwitchyardProcessManager(registry: registry, reclaimer: reclaimer(inspector))

    let report = await manager.reclaimLeftovers()

    #expect(report.isEmpty)
    #expect(inspector.signals.isEmpty)
    #expect(registry.records().isEmpty)
}

/// A server that ignores SIGTERM would otherwise keep both the port and this
/// call, which runs on the main actor.
@MainActor
@Test func stoppingAServerThatIgnoresTerminationStillReturns() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let binary = directory.appendingPathComponent("stubborn-server")
    try "#!/bin/sh\ntrap '' TERM\nexec /bin/sleep 30\n"
        .write(to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    let config = directory.appendingPathComponent("routes.toml")
    try SwitchyardConfigWriter.write(
        profile: RoutingProfile(
            provider: .codex,
            algorithm: .stageRouter,
            tiers: [
                TaskTier(name: "Efficient", summary: "Simple.", modelID: "gpt-5.3-codex-spark"),
                TaskTier(name: "Capable", summary: "Complex.", modelID: "gpt-6-astra"),
            ],
            port: 4198
        ),
        to: config
    )
    let registry = FakeRegistry()
    let manager = SwitchyardProcessManager(
        startupGracePeriod: .milliseconds(300), registry: registry, terminationTimeout: 0.5
    )

    try await manager.start(configPath: config, binaryPath: binary, port: 4198)
    let pid = try #require(manager.runningPID)
    #expect(registry.records().map(\.pid) == [pid])

    let started = Date()
    manager.stop()

    #expect(Date().timeIntervalSince(started) < 5)
    #expect(manager.status == .stopped)
    #expect(kill(pid, 0) != 0)
    #expect(registry.records().isEmpty)
}
