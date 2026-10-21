import Foundation
import Testing
@testable import SwitchyardDesktopKit

private func share(_ id: String, count: Int) -> RoutingMetrics.Share {
    RoutingMetrics.Share(
        id: id, target: nil, count: count, share: 0,
        requestsPerSecond: 0, tokens: 0, cachedTokens: 0
    )
}

@Test func flowMapOrdersRowsByEffortRatherThanTraffic() {
    // Busiest first, the way the metrics compute them.
    let shares = [share("light", count: 300), share("heavy", count: 4)]
    let roles = [
        "light": FlowRole(name: "Direct", effort: .low),
        "heavy": FlowRole(name: "Investigative", effort: .high),
    ]
    #expect(FlowRole.ordered(shares, roles: roles).map(\.id) == ["heavy", "light"])
}

@Test func roleNamingNoEffortSitsBelowEveryRankedRole() {
    let shares = [share("unranked", count: 900), share("cheap", count: 1)]
    let roles = [
        "unranked": FlowRole(name: "Default", effort: nil),
        "cheap": FlowRole(name: "Direct", effort: .low),
    ]
    #expect(FlowRole.ordered(shares, roles: roles).map(\.id) == ["cheap", "unranked"])
}

@Test func rowsAtOneLevelOrderByTrafficThenName() {
    let shares = [share("b", count: 5), share("a", count: 5), share("busy", count: 50)]
    let roles = Dictionary(uniqueKeysWithValues: shares.map {
        ($0.id, FlowRole(name: $0.id, effort: .medium))
    })
    #expect(FlowRole.ordered(shares, roles: roles).map(\.id) == ["busy", "a", "b"])
}

@Test func withoutRolesTheRowsKeepTheOrderTheMetricsComputed() {
    let shares = [share("busy", count: 40), share("quiet", count: 1)]
    #expect(FlowRole.ordered(shares, roles: [:]).map(\.id) == ["busy", "quiet"])
}

@Test func anIdleAssignmentKeepsItsPlaceOnTheLadder() {
    // A heavy role nobody hit this window still belongs above a busy light one:
    // the column ranks the work, not the traffic.
    let shares = [share("light", count: 272), share("heavy", count: 0)]
    let roles = [
        "light": FlowRole(name: "Direct", effort: .low),
        "heavy": FlowRole(name: "Deep reasoning", effort: .ultra),
    ]
    #expect(FlowRole.ordered(shares, roles: roles).map(\.id) == ["heavy", "light"])
}

@MainActor
@Test func flowRolesTakeTheHeaviestRoleAModelHolds() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("routing.jsonl")
    try "".write(to: log, atomically: true, encoding: .utf8)

    let model = WizardModel(
        sessionStore: ActiveRoutingSessionStore(fileURL: directory.appendingPathComponent("session.json")),
        restoreSavedSetup: false
    )
    let direct = RoutingRole(name: "Direct", text: "Small edits.", effort: .low)
    let investigative = RoutingRole(name: "Investigative", text: "Find the cause.", effort: .high)
    model.profile.roles = [RoutingRole.builtInClassifier, direct, investigative]
    model.profile.tiers = [
        TaskTier(name: "Quick", summary: "", modelID: "shared"),
        TaskTier(name: "Deep", summary: "", modelID: "shared"),
        TaskTier(name: "Unassigned", summary: "", modelID: nil),
    ]
    model.profile.tiers[0].roleID = direct.id
    model.profile.tiers[1].roleID = investigative.id

    let monitor = RoutingMonitor(model: model, logReader: RoutingLogReader(url: log))
    #expect(monitor.flowRoles == ["shared": FlowRole(name: "Investigative", effort: .high)])
}

@MainActor
@Test func aTargetWithoutARoleStillNamesItsRow() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("routing.jsonl")
    try "".write(to: log, atomically: true, encoding: .utf8)

    let model = WizardModel(
        sessionStore: ActiveRoutingSessionStore(fileURL: directory.appendingPathComponent("session.json")),
        restoreSavedSetup: false
    )
    model.profile.roles = [RoutingRole.builtInClassifier]
    model.profile.tiers = [TaskTier(name: "Capable", summary: "", modelID: "gpt-5-codex")]

    let monitor = RoutingMonitor(model: model, logReader: RoutingLogReader(url: log))
    #expect(monitor.flowRoles["gpt-5-codex"] == FlowRole(name: "Capable", effort: nil))
}
