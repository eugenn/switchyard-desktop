import Foundation
import Testing
@testable import SwitchyardDesktopKit

private func contextRecord(_ json: String, id: Int = 0) throws -> RoutingLogRecord {
    try #require(RoutingLogReader.record(from: json, id: id))
}

@Test func contextTracksLatestInputPerSessionAndModelAfterCompaction() throws {
    let records = try [
        // A newer judge call on the same model must not replace served usage.
        contextRecord(#"{"ts":500,"session_id":"a","model":"small","tier":"classifier","prompt_tokens":90000}"#),
        contextRecord(#"{"ts":400,"session_id":"b","model":"small","prompt_tokens":99000}"#),
        contextRecord(#"{"ts":300,"session_id":"a","model":"small","prompt_tokens":20000,"cached_tokens":18000,"completion_tokens":3000}"#),
        contextRecord(#"{"ts":200,"session_id":"a","model":"large","prompt_tokens":80000}"#),
        contextRecord(#"{"ts":100,"session_id":"a","model":"small","prompt_tokens":95000}"#),
    ]
    let windows = ["small": 100_000, "large": 400_000]
    let usage = ModelContextUsage.latest(records: records, sessionID: "a", contextWindows: windows)
    #expect(usage["small"]?.inputTokens == 20_000)
    #expect(usage["small"]?.fraction == 0.2)
    #expect(usage["large"]?.fraction == 0.2)
    #expect(usage.count == 2)
    // Timestamp ordering also handles a buffered log write arriving late.
    #expect(ModelContextUsage.latest(records: records.reversed(), sessionID: "a", contextWindows: windows) == usage)
    #expect(ModelContextUsage.latest(records: records, sessionID: "b", contextWindows: windows)["small"]?.fraction == 0.99)
}

@Test func missingContextUsageDoesNotBecomeZeroOrReuseAnOlderRequest() throws {
    for value in ["null", "-1", "true", "1.5", "\"invalid\""] {
        let record = try contextRecord("{\"prompt_tokens\":\(value)}")
        #expect(record.contextInputTokens == nil)
    }
    #expect(try contextRecord(#"{"usage":{"input_tokens":0}}"#).contextInputTokens == 0)
    #expect(try contextRecord(#"{"usage":{"input_tokens":"42"}}"#).contextInputTokens == 42)
    let records = try [
        contextRecord(#"{"ts":200,"session_id":"a","model":"m","total_tokens":9000}"#),
        contextRecord(#"{"ts":100,"session_id":"a","model":"m","prompt_tokens":5000}"#),
    ]
    let usage = try #require(ModelContextUsage.latest(records: records, sessionID: "a", contextWindows: ["m": 10_000])["m"])
    #expect(usage.inputTokens == nil)
    #expect(usage.fraction == nil)
    #expect(usage.percentage == "—")
    #expect(ModelContextUsage(inputTokens: 0, contextWindow: 10_000).fraction == 0)
    #expect(ModelContextUsage(inputTokens: 100, contextWindow: nil).fraction == nil)
    #expect(ModelContextUsage(inputTokens: 100, contextWindow: 0).fraction == nil)
    let overflow = ModelContextUsage(inputTokens: 12_000, contextWindow: 10_000)
    #expect(overflow.fraction == 1.2)
    #expect(overflow.fillFraction == 1)
}

@Test func contextCatalogReadsRealModelLimitsAndRefreshesChangedOrMissingData() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let reader = CodexModelContextReader(configPath: directory.appendingPathComponent("config.toml"))
    #expect(reader.contextWindows().isEmpty)
    try #"{"models":[{"slug":"m","context_window":272000,"effective_context_window_percent":95},{"slug":"zero","context_window":0},{"slug":"unknown","context_window":null},{"slug":"bad","context_window":true}]}"#
        .write(to: reader.url, atomically: true, encoding: .utf8)
    // The client safety margin does not change the model's actual window.
    #expect(reader.contextWindows() == ["m": 272_000])
    #expect(reader.contextWindows() == ["m": 272_000])
    try #"{"models":[{"slug":"m","context_window":128000}]}"#
        .write(to: reader.url, atomically: true, encoding: .utf8)
    #expect(reader.contextWindows() == ["m": 128_000])
    try "unfinished JSON".write(to: reader.url, atomically: true, encoding: .utf8)
    #expect(reader.contextWindows().isEmpty)
    try FileManager.default.removeItem(at: reader.url)
    #expect(reader.contextWindows().isEmpty)
}

@Test func contextUsesMaximumModelWindowRatherThanDefaultClientWindow() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let reader = CodexModelContextReader(configPath: directory.appendingPathComponent("config.toml"))
    try #"{"models":[{"slug":"gpt-6-astra","context_window":272000,"max_context_window":872000,"effective_context_window_percent":95},{"slug":"gpt-5.5","context_window":272000,"max_context_window":272000},{"slug":"legacy","context_window":128000},{"slug":"invalid-max","context_window":128000,"max_context_window":0},{"slug":"null-max","context_window":128000,"max_context_window":null},{"slug":"bool-max","context_window":128000,"max_context_window":true}]}"#
        .write(to: reader.url, atomically: true, encoding: .utf8)
    let windows = reader.contextWindows()
    #expect(windows["gpt-6-astra"] == 872_000)
    #expect(windows["gpt-5.5"] == 272_000)
    for id in ["legacy", "invalid-max", "null-max", "bool-max"] {
        #expect(windows[id] == 128_000)
    }
    // Reproduce a completed request from an old session: its input exceeds
    // Codex's default window but fits the model's reported maximum.
    let astra = ModelContextUsage(inputTokens: 324_881, contextWindow: windows["gpt-6-astra"])
    #expect(astra.fraction == 324_881.0 / 872_000)
    #expect(try #require(astra.fraction) < 1)
    let gpt55 = ModelContextUsage(inputTokens: 252_550, contextWindow: windows["gpt-5.5"])
    #expect(gpt55.fraction == 252_550.0 / 272_000)
}

@MainActor
@Test func monitorContextFollowsSessionAndCatalogChangesWithoutUsingRouteWindowAsModelCapacity() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("routing.jsonl")
    let config = directory.appendingPathComponent("routes.toml")
    let catalog = directory.appendingPathComponent("models_cache.json")
    try """
    {"ts":100,"route_id":"route","session_id":"a","model":"m","prompt_tokens":50000}
    {"ts":200,"route_id":"route","session_id":"b","model":"m","prompt_tokens":10000}
    """.write(to: log, atomically: true, encoding: .utf8)
    try """
    [routes.main]
    id = "route"
    context_window = 200000
    recent_turn_window = 3
    classifier_max_tokens = 4096
    """.write(to: config, atomically: true, encoding: .utf8)
    try #"{"models":[{"slug":"m","context_window":100000}]}"#
        .write(to: catalog, atomically: true, encoding: .utf8)
    let model = WizardModel(
        routingConfigPath: config, codexConfigPath: directory.appendingPathComponent("config.toml"),
        sessionStore: ActiveRoutingSessionStore(fileURL: directory.appendingPathComponent("session.json")),
        restoreSavedSetup: false
    )
    let monitor = RoutingMonitor(model: model, logReader: RoutingLogReader(url: log))
    await monitor.refresh()
    // Nothing picked: the gauges read the newest conversation.
    #expect(monitor.contextSession?.id == "b")
    #expect(monitor.sessionContextUsage["m"]?.fraction == 0.1)
    monitor.selectedSessionID = "a"
    #expect(monitor.sessionRouteContextWindow == 200_000)
    #expect(monitor.sessionContextUsage["m"]?.fraction == 0.5)
    monitor.selectedSessionID = "b"
    #expect(monitor.sessionContextUsage["m"]?.fraction == 0.1)
    monitor.range = .fifteenMinutes
    monitor.selectedModelID = "another-model"
    #expect(monitor.sessionContextUsage["m"]?.fraction == 0.1)
    try #"{"models":[{"slug":"m","context_window":200000}]}"#
        .write(to: catalog, atomically: true, encoding: .utf8)
    await monitor.refresh()
    #expect(monitor.sessionContextUsage["m"]?.fraction == 0.05)
    try #"{"ts":300,"route_id":"route","session_id":"b","model":"m","prompt_tokens":20000}"#
        .write(to: log, atomically: true, encoding: .utf8)
    await monitor.refresh()
    #expect(monitor.sessionContextUsage["m"]?.fraction == 0.1)
    // A pick that aged out of the log falls back to the newest conversation.
    monitor.selectedSessionID = "gone"
    #expect(monitor.contextSession?.id == "b")
    #expect(monitor.sessionContextUsage["m"]?.fraction == 0.1)
}

@MainActor
@Test func unpickedFlowFollowsTheNewestConversationAndMarksEveryLiveOne() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("routing.jsonl")
    let config = directory.appendingPathComponent("routes.toml")
    let catalog = directory.appendingPathComponent("models_cache.json")
    let now = Date().timeIntervalSince1970
    try """
    {"ts":\(now - 30),"route_id":"route","session_id":"a","model":"m","prompt_tokens":50000}
    """.write(to: log, atomically: true, encoding: .utf8)
    try """
    [routes.main]
    id = "route"
    context_window = 200000
    recent_turn_window = 3
    classifier_max_tokens = 4096
    """.write(to: config, atomically: true, encoding: .utf8)
    try #"{"models":[{"slug":"m","context_window":100000}]}"#
        .write(to: catalog, atomically: true, encoding: .utf8)
    let model = WizardModel(
        routingConfigPath: config, codexConfigPath: directory.appendingPathComponent("config.toml"),
        sessionStore: ActiveRoutingSessionStore(fileURL: directory.appendingPathComponent("session.json")),
        restoreSavedSetup: false
    )
    let monitor = RoutingMonitor(model: model, logReader: RoutingLogReader(url: log))
    await monitor.refresh()

    #expect(monitor.selectedSessionID == nil)
    #expect(monitor.activeSessionIDs == ["a"])
    #expect(monitor.contextSession?.id == "a")
    #expect(monitor.sessionContextUsage["m"]?.fraction == 0.5)
    #expect(monitor.sessionRouteContextWindow == 200_000)

    // A second live conversation: the map follows the newer one, and both
    // stay marked live for the picker.
    try """
    {"ts":\(now - 30),"route_id":"route","session_id":"a","model":"m","prompt_tokens":50000}
    {"ts":\(now - 10),"route_id":"route","session_id":"b","model":"m","prompt_tokens":10000}
    """.write(to: log, atomically: true, encoding: .utf8)
    await monitor.refresh()
    #expect(monitor.activeSessionIDs == ["a", "b"])
    #expect(monitor.contextSession?.id == "b")
    #expect(monitor.sessionContextUsage["m"]?.fraction == 0.1)
    #expect(monitor.sessionRouteContextWindow == 200_000)

    // An explicit pick names the older one.
    monitor.selectedSessionID = "a"
    #expect(monitor.contextSession?.id == "a")
    #expect(monitor.sessionContextUsage["m"]?.fraction == 0.5)

    // A conversation that has gone quiet is no longer live, but the map still
    // shows it as the newest one the log holds.
    try #"{"ts":\#(now - 3_600),"route_id":"route","session_id":"c","model":"m","prompt_tokens":70000}"#
        .write(to: log, atomically: true, encoding: .utf8)
    await monitor.refresh()
    monitor.selectedSessionID = nil
    #expect(monitor.activeSessionIDs.isEmpty)
    #expect(monitor.contextSession?.id == "c")
    #expect(monitor.sessionContextUsage["m"]?.fraction == 0.7)
}

@Test func switchyardContextDeclarationsAreKeyedByPublicRouteID() {
    let payload: [String: Any] = ["data": [
        ["id": "route", "capabilities": ["context_window": 128_000]],
        ["id": "unset", "capabilities": ["context_window": NSNull()]],
        ["id": "zero", "capabilities": ["context_window": 0]],
        ["id": "invalid", "capabilities": ["context_window": true]],
    ]]
    #expect(SwitchyardRouteContext.advertisedWindows(in: payload) == ["route": 128_000])
}

private func rollout(_ directory: URL, day: String, sessionID: String, lines: [String]) throws -> URL {
    let folder = directory.appendingPathComponent("2026/09/\(day)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("rollout-2026-09-\(day)T09-00-00-\(sessionID).jsonl")
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Test func sessionWindowComesFromCodexOwnRolloutForThatConversation() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    // A conversation whose rollout Codex has not written yet is retried.
    let reader = CodexSessionContextReader(directory: directory, missRetryInterval: 0)
    #expect(reader.contextWindow(sessionID: "01a0-9be3cd") == nil)

    let url = try rollout(directory, day: "16", sessionID: "01a0-9be3cd", lines: [
        #"{"payload":{"type":"task_started","model_context_window":null}}"#,
        #"{"payload":{"type":"token_count","info":{"model_context_window":258400}}}"#,
    ])
    // An older conversation of the same day is not confused with it.
    _ = try rollout(directory, day: "15", sessionID: "other", lines: [
        #"{"payload":{"info":{"model_context_window":128000}}}"#
    ])
    #expect(reader.contextWindow(sessionID: "01a0-9be3cd") == 258_400)
    #expect(reader.contextWindow(sessionID: "other") == 128_000)
    #expect(reader.contextWindow(sessionID: "") == nil)
    #expect(reader.contextWindow(sessionID: "never-routed-by-codex") == nil)

    // A later turn wins, including the window a model change brings.
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(("\n" + #"{"payload":{"info":{"model_context_window":400000}}}"#).utf8))
    try handle.close()
    #expect(reader.contextWindow(sessionID: "01a0-9be3cd") == 400_000)

    // A rollout that has not reported a window yet stays unknown rather than 0.
    #expect(CodexSessionContextReader.lastWindow(in: Data()) == nil)
    #expect(CodexSessionContextReader.lastWindow(in: Data(#"{"model_context_window":0}"#.utf8)) == nil)
    #expect(CodexSessionContextReader.lastWindow(in: Data(#"{"model_context_window": 12}"#.utf8)) == 12)
    #expect(CodexSessionContextReader.lastWindow(in: Data(#"{"other_context_window":9}"#.utf8)) == nil)
}

@MainActor
@Test func routedModelWithoutACatalogEntryFallsBackToTheConversationWindow() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("routing.jsonl")
    let config = directory.appendingPathComponent("routes.toml")
    let sessions = directory.appendingPathComponent("sessions")
    try #"{"ts":100,"route_id":"route","session_id":"a","model":"gpt-5.6-sol","prompt_tokens":92400}"#
        .write(to: log, atomically: true, encoding: .utf8)
    try "[routes.main]\nid = \"route\"\n".write(to: config, atomically: true, encoding: .utf8)
    _ = try rollout(sessions, day: "16", sessionID: "a", lines: [
        #"{"payload":{"info":{"model_context_window":258400}}}"#
    ])
    let model = WizardModel(
        routingConfigPath: config, codexConfigPath: directory.appendingPathComponent("config.toml"),
        sessionStore: ActiveRoutingSessionStore(fileURL: directory.appendingPathComponent("session.json")),
        restoreSavedSetup: false
    )
    // The catalog Codex writes while routing names no model at all.
    let monitor = RoutingMonitor(
        model: model, logReader: RoutingLogReader(url: log),
        sessionContextReader: CodexSessionContextReader(directory: sessions))
    await monitor.refresh()
    monitor.selectedSessionID = "a"
    let usage = try #require(monitor.sessionContextUsage["gpt-5.6-sol"])
    #expect(usage.contextWindow == 258_400)
    #expect(usage.windowSource == .session)
    #expect(usage.tokenLabel == "92.4K / 258.4K")
    #expect(usage.explanation.contains("this conversation"))
    #expect(usage.percentage != "—")
}

@Test func catalogWindowStillWinsOverTheConversationWindow() throws {
    let records = try [
        contextRecord(#"{"ts":100,"session_id":"a","model":"known","prompt_tokens":10000}"#),
        contextRecord(#"{"ts":100,"session_id":"a","model":"unlisted","prompt_tokens":10000}"#),
    ]
    let usage = ModelContextUsage.latest(
        records: records, sessionID: "a", contextWindows: ["known": 400_000], sessionWindow: 200_000)
    #expect(usage["known"]?.contextWindow == 400_000)
    #expect(usage["known"]?.windowSource == .catalog)
    #expect(usage["unlisted"]?.contextWindow == 200_000)
    #expect(usage["unlisted"]?.windowSource == .session)
    // No conversation window either: the row stays honest about the gap.
    let unknown = ModelContextUsage.latest(
        records: records, sessionID: "a", contextWindows: [:], sessionWindow: nil)
    #expect(unknown["known"]?.contextWindow == nil)
    #expect(unknown["known"]?.percentage == "—")
}

/// Codex measures the conversation against the window the route advertises, so
/// a model's own larger maximum is not the limit the card should show.
@Test func aRouteWindowBelowTheModelsMaximumIsTheLimitShown() throws {
    let records = try [
        contextRecord(#"{"ts":300,"session_id":"a","model":"large","prompt_tokens":136000}"#),
        contextRecord(#"{"ts":200,"session_id":"a","model":"small","prompt_tokens":50000}"#),
    ]
    let windows = ["large": 872_000, "small": 100_000]

    let usage = ModelContextUsage.latest(
        records: records, sessionID: "a", contextWindows: windows, routeWindow: 272_000)

    #expect(usage["large"]?.contextWindow == 272_000)
    #expect(usage["large"]?.fraction == 0.5)
    #expect(usage["large"]?.windowSource == .route)
    // A model already under the route window keeps its own.
    #expect(usage["small"]?.contextWindow == 100_000)
    #expect(usage["small"]?.windowSource == .catalog)
}
