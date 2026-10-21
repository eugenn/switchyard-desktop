import Foundation
import Observation
import Testing
@testable import SwitchyardDesktopKit

@MainActor
@Test func modelSelectionFiltersHistoryWithoutChangingTheRecentFlow() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("routing.jsonl")
    let now = Date()
    let records: [[String: Any]] = [
        ["ts": now.addingTimeInterval(-60).timeIntervalSince1970, "model": "efficient", "total_tokens": 100],
        ["ts": now.addingTimeInterval(-120).timeIntervalSince1970, "model": "capable", "total_tokens": 900],
        ["ts": now.addingTimeInterval(-3_600).timeIntervalSince1970, "model": "efficient", "total_tokens": 300],
    ]
    let text = try records.map { record in
        String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
    }.joined(separator: "\n")
    try text.write(to: log, atomically: true, encoding: .utf8)
    let model = WizardModel(
        sessionStore: ActiveRoutingSessionStore(fileURL: directory.appendingPathComponent("session.json")),
        restoreSavedSetup: false
    )
    model.profile.tiers = [
        TaskTier(name: "Efficient", summary: "", modelID: "efficient"),
        TaskTier(name: "Capable", summary: "", modelID: "capable"),
        TaskTier(name: "Idle", summary: "", modelID: "idle"),
    ]
    let monitor = RoutingMonitor(model: model, logReader: RoutingLogReader(url: log))
    await monitor.refresh()
    #expect(monitor.pane == .statistics)
    #expect(monitor.activityMetrics.count == 2)
    #expect(monitor.selectedModelMetrics.count == 3)
    #expect(monitor.selectedModelMetrics.buckets.count == 72)
    #expect(
        monitor.selectedModelMetrics.buckets[1].start
            .timeIntervalSince(monitor.selectedModelMetrics.buckets[0].start) == 5 * 60
    )
    #expect(monitor.activityMetrics.shares.first { $0.id == "idle" }?.share == 0)

    monitor.selectedModelID = "efficient"
    #expect(monitor.selectedModelMetrics.count == 2)
    #expect(monitor.selectedModelMetrics.tokens == 400)
    // The recent flow keeps its own fixed window while the history changes.
    #expect(monitor.activityMetrics.count == 2)
    monitor.range = .fifteenMinutes
    #expect(monitor.selectedModelMetrics.count == 1)
    #expect(monitor.selectedModelMetrics.buckets.count == 3)
    #expect(monitor.activityMetrics.count == 2)
    monitor.selectedModelID = "idle"
    #expect(monitor.selectedModelMetrics.isEmpty)

    // Repeated view reads must keep tracking profile edits, even after a cache hit.
    #expect(monitor.metrics == monitor.metrics)
    await confirmation("A cached summary still observes profile edits") { changed in
        withObservationTracking {
            _ = monitor.metrics
        } onChange: {
            changed()
        }
        model.profile.tiers[2].modelID = "replacement"
    }
    #expect(monitor.metrics.shares.contains { $0.id == "replacement" })
    #expect(!monitor.activityMetrics.shares.contains { $0.id == "idle" })
    #expect(monitor.modelIDs.contains("replacement"))
    #expect(monitor.activityMetrics.shares.contains { $0.id == "replacement" })
    _ = monitor.activityMetrics
    model.profile.tiers[2].name = "Renamed"
    #expect(monitor.activityMetrics.shares.first { $0.id == "replacement" }?.target == "Renamed")

    // A refresh advances the windows even when the log bytes have not changed.
    let previousRefresh = try #require(monitor.lastRefresh)
    await confirmation("A cached summary still observes a refresh") { changed in
        withObservationTracking {
            _ = monitor.metrics
        } onChange: {
            changed()
        }
        await monitor.refresh()
    }
    #expect(monitor.metrics.windowEnd == monitor.lastRefresh)
    #expect(monitor.metrics.windowEnd >= previousRefresh)

    try "{\"model\":\"fresh\",\"total_tokens\":5}\n".write(to: log, atomically: true, encoding: .utf8)
    await monitor.refresh()
    monitor.selectedModelID = nil
    #expect(monitor.metrics.count == 1)
    #expect(monitor.activityMetrics.tokens == 5)
    #expect(monitor.selectedModelMetrics.tokens == 5)
    #expect(monitor.filteredRecords.map(\.model) == ["fresh"])
}

@MainActor
@Test func aHiddenWindowStopsPollingUntilItBecomesVisible() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent("config.toml")
    let model = WizardModel(
        sessionStore: ActiveRoutingSessionStore(fileURL: directory.appendingPathComponent("session.json")),
        restoreSavedSetup: false
    )
    let monitor = RoutingMonitor(
        model: model,
        logReader: RoutingLogReader(url: directory.appendingPathComponent("routing.jsonl")),
        sessionNameReader: CodexSessionNameReader(url: directory.appendingPathComponent("session_index.jsonl")),
        modelContextReader: CodexModelContextReader(configPath: config),
        sessionContextReader: CodexSessionContextReader(directory: directory),
        pollInterval: .milliseconds(20)
    )
    defer { monitor.endPolling() }

    monitor.setWindowVisible(false)
    monitor.beginPolling()
    try await Task.sleep(for: .milliseconds(80))
    #expect(monitor.lastRefresh == nil)

    monitor.setWindowVisible(true)
    try await waitUntil { monitor.lastRefresh != nil }
    let visibleRefresh = try #require(monitor.lastRefresh)

    // Let a refresh already in flight land before measuring the paused state.
    monitor.setWindowVisible(false)
    try await Task.sleep(for: .milliseconds(80))
    let pausedRefresh = monitor.lastRefresh
    try await Task.sleep(for: .milliseconds(80))
    #expect(monitor.lastRefresh == pausedRefresh)

    monitor.setWindowVisible(true)
    try await waitUntil { monitor.lastRefresh != pausedRefresh }
    #expect(monitor.lastRefresh != visibleRefresh)
}

/// Polls `condition` on the main actor until it holds, so a loaded test run only slows
/// the test down instead of failing it on a fixed sleep.
@MainActor
private func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
@Test func theRequestFilterSeparatesJudgeCallsFromServedTurns() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("routing.jsonl")
    let now = Date().timeIntervalSince1970
    let records: [[String: Any]] = [
        ["ts": now - 30, "model": "judge", "tier": "classifier", "total_tokens": 3_000],
        ["ts": now - 20, "model": "efficient", "tier": "", "total_tokens": 100],
    ]
    let text = try records.map {
        String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
    }.joined(separator: "\n")
    try text.write(to: log, atomically: true, encoding: .utf8)
    let model = WizardModel(
        sessionStore: ActiveRoutingSessionStore(fileURL: directory.appendingPathComponent("session.json")),
        restoreSavedSetup: false
    )
    model.profile.tiers = [TaskTier(name: "Efficient", summary: "", modelID: "efficient")]
    let monitor = RoutingMonitor(model: model, logReader: RoutingLogReader(url: log))
    await monitor.refresh()

    #expect(monitor.filteredRecords.count == 2)
    // A judge call is overhead, not a served turn.
    #expect(monitor.metrics.count == 1)
    #expect(monitor.metrics.classifierCount == 1)

    monitor.filter = .routed
    #expect(monitor.filteredRecords.map(\.model) == ["efficient"])
    #expect(monitor.role(for: try #require(monitor.filteredRecords.first)) == "Efficient")

    monitor.filter = .classifier
    let judge = try #require(monitor.filteredRecords.first)
    #expect(judge.model == "judge")
    #expect(monitor.role(for: judge) == "classifier")
}

@MainActor
@Test func aPickedSessionNarrowsTheFlowMapToThatConversation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("routing.jsonl")
    let now = Date().timeIntervalSince1970
    let records: [[String: Any]] = [
        ["ts": now - 30, "session_id": "live", "model": "efficient", "total_tokens": 100],
        ["ts": now - 45, "session_id": "live", "model": "judge", "tier": "classifier", "total_tokens": 20],
        ["ts": now - 60, "session_id": "live", "model": "efficient", "total_tokens": 100],
        ["ts": now - 300, "session_id": "earlier", "model": "capable", "total_tokens": 900],
        // Older than the flow map's own 15m window, but inside its session.
        ["ts": now - 5_400, "session_id": "earlier", "model": "capable", "total_tokens": 900],
    ]
    let text = try records.map {
        String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
    }.joined(separator: "\n")
    try text.write(to: log, atomically: true, encoding: .utf8)
    let model = WizardModel(
        sessionStore: ActiveRoutingSessionStore(fileURL: directory.appendingPathComponent("session.json")),
        restoreSavedSetup: false
    )
    model.profile.tiers = [
        TaskTier(name: "Efficient", summary: "", modelID: "efficient"),
        TaskTier(name: "Capable", summary: "", modelID: "capable"),
    ]
    let monitor = RoutingMonitor(model: model, logReader: RoutingLogReader(url: log))
    await monitor.refresh()

    #expect(monitor.sessions.map(\.id) == ["live", "earlier"])
    #expect(monitor.selectedSession == nil)
    // Unpicked, the flow map shows the newest conversation, never all of them.
    #expect(monitor.flowSession?.id == "live")
    #expect(monitor.activityMetrics.count == 2)
    let modelIDs = monitor.modelIDs

    monitor.selectedSessionID = "live"
    #expect(monitor.activityMetrics.count == 2)
    #expect(monitor.activityMetrics.classifierCount == 1)
    #expect(monitor.activityMetrics.shares.first { $0.id == "capable" }?.count == 0)

    // The older session keeps the turn that fell outside the 15m window, since
    // its window is the session's own lifetime.
    monitor.selectedSessionID = "earlier"
    #expect(monitor.activityMetrics.count == 2)
    #expect(monitor.activityMetrics.shares.first { $0.id == "capable" }?.share == 1)
    #expect(monitor.activityMetrics.windowStart == monitor.selectedSession?.startedAt)
    // A lane keeps its colour when the map is narrowed.
    #expect(monitor.modelIDs == modelIDs)

    // A session that has aged out of the log falls back to the newest one.
    monitor.selectedSessionID = "gone"
    #expect(monitor.selectedSession == nil)
    #expect(monitor.flowSession?.id == "live")
    #expect(monitor.activityMetrics.count == 2)
}

@MainActor
@Test func aPickedSessionAlsoNarrowsTheRequestListAndNamesIt() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("routing.jsonl")
    let index = directory.appendingPathComponent("session_index.jsonl")
    let now = Date().timeIntervalSince1970
    let records: [[String: Any]] = [
        ["ts": now - 30, "session_id": "live", "model": "efficient", "total_tokens": 100],
        ["ts": now - 45, "session_id": "live", "model": "judge", "tier": "classifier", "total_tokens": 20],
        ["ts": now - 300, "session_id": "earlier", "model": "capable", "total_tokens": 900],
        // Far outside the 6h range the pane defaults to.
        ["ts": now - 40_000, "session_id": "earlier", "model": "capable", "total_tokens": 900],
    ]
    try records.map {
        String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
    }.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
    try #"{"id":"earlier","thread_name":"Cut the 0.4 release"}"#
        .write(to: index, atomically: true, encoding: .utf8)

    let model = WizardModel(
        sessionStore: ActiveRoutingSessionStore(fileURL: directory.appendingPathComponent("session.json")),
        restoreSavedSetup: false
    )
    model.profile.tiers = [TaskTier(name: "Efficient", summary: "", modelID: "efficient")]
    let monitor = RoutingMonitor(
        model: model, logReader: RoutingLogReader(url: log),
        sessionNameReader: CodexSessionNameReader(url: index)
    )
    await monitor.refresh()

    #expect(monitor.filteredRecords.count == 3)
    #expect(monitor.recordScopeName == "the last 6 hours")
    // Codex's own name for the conversation, and the id for the one it has not named.
    #expect(monitor.sessions.map(\.title) == ["Session live", "Cut the 0.4 release"])

    monitor.selectedSessionID = "live"
    #expect(monitor.filteredRecords.count == 2)
    #expect(monitor.recordScopeName == "session live")
    monitor.filter = .routed
    #expect(monitor.filteredRecords.map(\.model) == ["efficient"])

    // A picked session replaces the window, so a turn older than the range stays.
    monitor.filter = .all
    monitor.selectedSessionID = "earlier"
    #expect(monitor.filteredRecords.count == 2)
    #expect(monitor.recordScopeName == "Cut the 0.4 release")
    #expect(monitor.sessionName(for: try #require(monitor.filteredRecords.first)) == "Cut the 0.4 release")

    monitor.selectedSessionID = nil
    #expect(monitor.filteredRecords.count == 3)
}

private func writeLog(_ records: [[String: Any]], to log: URL) throws {
    let text = try records.map {
        String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
    }.joined(separator: "\n")
    try text.write(to: log, atomically: true, encoding: .utf8)
}

/// Starting a route empties the window: the log's earlier turns belong to the
/// run before it, and so does whatever session and request were picked.
@MainActor
@Test func aNewRunStartsTheWindowFromZero() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("routing.jsonl")
    let now = Date().timeIntervalSince1970
    try writeLog([
        ["ts": now - 120, "session_id": "earlier", "model": "efficient", "total_tokens": 100],
        ["ts": now - 90, "session_id": "earlier", "model": "efficient", "total_tokens": 100],
    ], to: log)
    let model = WizardModel(
        sessionStore: ActiveRoutingSessionStore(fileURL: directory.appendingPathComponent("session.json")),
        restoreSavedSetup: false
    )
    model.profile.tiers = [TaskTier(name: "Efficient", summary: "", modelID: "efficient")]
    let monitor = RoutingMonitor(model: model, logReader: RoutingLogReader(url: log))
    await monitor.refresh()
    #expect(monitor.records.count == 2)
    monitor.selectedSessionID = "earlier"
    monitor.selectedRecordID = monitor.records.first?.id

    monitor.followRun(startedAt: Date(timeIntervalSince1970: now - 30))

    #expect(monitor.records.isEmpty)
    #expect(monitor.sessions.isEmpty)
    #expect(monitor.activityMetrics.count == 0)
    #expect(monitor.sessionCost == TokenCostEstimate.estimate(records: [], prices: monitor.prices, aliases: [:]))
    #expect(monitor.selectedSessionID == nil)
    #expect(monitor.selectedRecordID == nil)
    #expect(monitor.awaitsFirstSession)

    // A poll with no route running keeps the run the window describes.
    await monitor.refresh()
    #expect(monitor.records.isEmpty)
}

/// The run's first conversation fills the picker by itself, preferring one
/// that is live, and only once: a later session does not take its place.
@MainActor
@Test func theFirstSessionOfARunIsPickedForTheUser() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("routing.jsonl")
    let now = Date().timeIntervalSince1970
    let earlier: [String: Any] = ["ts": now - 120, "session_id": "earlier", "model": "efficient"]
    try writeLog([earlier], to: log)
    let model = WizardModel(
        sessionStore: ActiveRoutingSessionStore(fileURL: directory.appendingPathComponent("session.json")),
        restoreSavedSetup: false
    )
    let monitor = RoutingMonitor(model: model, logReader: RoutingLogReader(url: log))
    monitor.followRun(startedAt: Date(timeIntervalSince1970: now - 60))
    await monitor.refresh()
    #expect(monitor.selectedSessionID == nil)
    #expect(monitor.awaitsFirstSession)

    try writeLog([earlier, ["ts": now - 10, "session_id": "first", "model": "efficient"]], to: log)
    await monitor.refresh()
    #expect(monitor.selectedSessionID == "first")
    #expect(!monitor.awaitsFirstSession)

    try writeLog([
        earlier,
        ["ts": now - 10, "session_id": "first", "model": "efficient"],
        ["ts": now - 5, "session_id": "second", "model": "efficient"],
    ], to: log)
    await monitor.refresh()
    #expect(monitor.selectedSessionID == "first")
    #expect(monitor.sessions.map(\.id) == ["second", "first"])
}
