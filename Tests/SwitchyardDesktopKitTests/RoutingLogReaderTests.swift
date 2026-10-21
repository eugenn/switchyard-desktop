import Foundation
import Testing
@testable import SwitchyardDesktopKit

private func makeRoutingLog(_ lines: [String]) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let log = directory.appendingPathComponent("routing-log.jsonl")
    try (lines.joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)
    return log
}

/// A verbatim record from `switchyard-server --routing-log-file`.
@Test func readerDecodesASwitchyardRecord() throws {
    let log = try makeRoutingLog([
        """
        {"ts":"2026-09-12T08:46:09.794Z","route_id":"switchyard-desktop",\
        "algorithm":"llm_task_classifier","task":null,"trial_id":null,\
        "session_id":"01a094ca-30e4-7d70-b380-8bf19af93837","model":"gpt-5.6-terra","tier":"",\
        "prompt_tokens":65411,"cached_tokens":62720,"cache_creation_tokens":0,\
        "completion_tokens":312,"reasoning_tokens":121,"total_tokens":65723}
        """
    ])
    defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }

    let records = RoutingLogReader(url: log).recentRecords()

    #expect(records.count == 1)
    let record = try #require(records.first)
    #expect(record.model == "gpt-5.6-terra")
    #expect(record.route == "switchyard-desktop")
    #expect(record.algorithm == "llm_task_classifier")
    #expect(record.sessionID == "01a094ca-30e4-7d70-b380-8bf19af93837")
    // A served turn carries an empty tier and no task.
    #expect(record.tier == nil)
    #expect(record.task == nil)
    #expect(!record.isClassifier)
    #expect(record.tokens.prompt == 65411)
    #expect(record.tokens.cached == 62720)
    #expect(record.tokens.completion == 312)
    #expect(record.tokens.reasoning == 121)
    #expect(record.tokens.total == 65723)
    #expect(record.timestamp != nil)
}

@Test func readerRecognisesAJudgeCall() throws {
    let log = try makeRoutingLog([
        """
        {"ts":"2026-09-12T08:59:24.053Z","route_id":"switchyard-desktop",\
        "algorithm":"llm_task_classifier","session_id":"s1","model":"gpt-5.6-luna",\
        "tier":"classifier","prompt_tokens":3382,"completion_tokens":43,"total_tokens":3425}
        """
    ])
    defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }

    let record = try #require(RoutingLogReader(url: log).recentRecords().first)
    #expect(record.isClassifier)
    #expect(record.tier == "classifier")
}

@Test func readerReturnsNewestRecordFirst() throws {
    let log = try makeRoutingLog([
        #"{"timestamp":"2026-09-11T10:00:00Z","selected_model":"a"}"#,
        #"{"timestamp":"2026-09-11T10:05:00Z","selected_model":"b"}"#,
        #"{"timestamp":"2026-09-11T10:10:00Z","selected_model":"c"}"#,
    ])
    defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }

    let records = RoutingLogReader(url: log).recentRecords()

    #expect(records.map(\.model) == ["c", "b", "a"])
}

@Test func readerKeepsUnknownFieldsVerbatimAndFlattensNestedOnes() throws {
    let log = try makeRoutingLog([
        #"{"selected_model":"gpt","tokens":{"prompt":1284,"completion":342},"streaming":false}"#
    ])
    defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }

    let record = try #require(RoutingLogReader(url: log).recentRecords().first)

    #expect(record.fields.contains { $0.name == "tokens.prompt" && $0.value == "1284" })
    #expect(record.fields.contains { $0.name == "tokens.completion" && $0.value == "342" })
    #expect(record.fields.contains { $0.name == "streaming" && $0.value == "false" })
}

/// Delegated work carries the parent's session id, so only the agent identity
/// tells the two apart.
@Test func readerReadsTheAgentLineageOfDelegatedWork() throws {
    let log = try makeRoutingLog([
        """
        {"ts":"2026-09-20T08:46:09.794Z","route_id":"switchyard-desktop","algorithm":"passthrough",\
        "session_id":"01a094ca-30e4-7d70-b380-8bf19af93837","agent_id":"child-7",\
        "parent_agent_id":"thread-1","delegated":true,"agent_kind":"review",\
        "agent_role":"reviewer","model":"gpt-5.6-luna","tier":"",\
        "prompt_tokens":1200,"completion_tokens":48,"total_tokens":1248}
        """
    ])
    defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }

    let record = try #require(RoutingLogReader(url: log).recentRecords().first)

    #expect(record.agentID == "child-7")
    #expect(record.parentAgentID == "thread-1")
    #expect(record.isDelegated)
    #expect(record.agentKind == "review")
    #expect(record.agentRole == "reviewer")
    #expect(record.subagentIdentityUnsupported == false)
    // The child is logged under the conversation it was spawned from.
    #expect(record.sessionID == "01a094ca-30e4-7d70-b380-8bf19af93837")
}

/// Switchyard omits the agent fields for a harness that reports none, and says
/// so explicitly when the harness has children it cannot name.
@Test func readerReadsAPlainTurnAsNotDelegated() throws {
    let log = try makeRoutingLog([
        #"{"session_id":"s1","model":"gpt-5.6-terra","prompt_tokens":10}"#,
        #"{"session_id":"s1","model":"gpt-5.6-terra","subagent_identity_unsupported":true}"#,
    ])
    defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }

    let records = RoutingLogReader(url: log).recentRecords()

    let unsupported = try #require(records.first)
    #expect(unsupported.subagentIdentityUnsupported)
    #expect(!unsupported.isDelegated)
    let plain = try #require(records.last)
    #expect(plain.agentID == nil)
    #expect(plain.parentAgentID == nil)
    #expect(!plain.isDelegated)
    #expect(!plain.subagentIdentityUnsupported)
}

/// Switchyard owns the schema, so a renamed or older field still has to land.
@Test func readerAcceptsAlternativeFieldNamesAndEpochTimes() throws {
    let log = try makeRoutingLog([
        #"{"time":1789000000,"selected_target":"docs","selected_model":"gpt-5.3","input_tokens":"41","output_tokens":9}"#
    ])
    defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }

    let record = try #require(RoutingLogReader(url: log).recentRecords().first)

    #expect(record.tier == "docs")
    #expect(record.model == "gpt-5.3")
    #expect(record.tokens.prompt == 41)
    #expect(record.tokens.completion == 9)
    // A record without its own sum still reports a total.
    #expect(record.tokens.total == 50)
    #expect(record.timestamp == Date(timeIntervalSince1970: 1_789_000_000))
}

@Test func readerSkipsBrokenLinesAndMissingLogs() throws {
    let log = try makeRoutingLog([
        "not json at all",
        #"{"selected_model":"gpt-5.6-sol"}"#,
        "{\"unterminated\": ",
    ])
    defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }

    #expect(RoutingLogReader(url: log).recentRecords().count == 1)

    let absent = log.deletingLastPathComponent().appendingPathComponent("none.jsonl")
    #expect(RoutingLogReader(url: absent).logExists == false)
    #expect(RoutingLogReader(url: absent).recentRecords().isEmpty)
}

@Test func readerHonorsItsRecordLimit() throws {
    let log = try makeRoutingLog(
        (0..<20).map { #"{"selected_model":"m\#($0)"}"# }
    )
    defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }

    #expect(RoutingLogReader(url: log).recentRecords(limit: 5).count == 5)
}

@Test func readerRefreshesAfterAppendReplacementTruncationAndRemoval() throws {
    let log = try makeRoutingLog([#"{"model":"old"}"#])
    defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }
    let reader = RoutingLogReader(url: log)
    let initial = reader.recentRecords()
    #expect(reader.recentRecords() == initial)

    let handle = try FileHandle(forWritingTo: log)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"model\":\"new\"}\n".utf8))
    try handle.close()
    #expect(reader.recentRecords().map(\.model) == ["new", "old"])
    #expect(reader.recentRecords(limit: 1).map(\.model) == ["new"])
    #expect(reader.recentRecords(limit: 2).map(\.model) == ["new", "old"])
    #expect(reader.recentRecords(limit: 0).isEmpty)
    #expect(reader.recentRecords(limit: -1).isEmpty)

    // Same-sized replacement must not reuse data just because its size matches.
    try "{\"model\":\"one\"}\n{\"model\":\"two\"}\n".write(to: log, atomically: true, encoding: .utf8)
    #expect(reader.recentRecords().map(\.model) == ["two", "one"])
    try "".write(to: log, atomically: false, encoding: .utf8)
    #expect(reader.recentRecords().isEmpty)
    try FileManager.default.removeItem(at: log)
    #expect(reader.recentRecords().isEmpty)
    try "{\"model\":\"reborn\"}\n".write(to: log, atomically: true, encoding: .utf8)
    #expect(reader.recentRecords().map(\.model) == ["reborn"])
}

@Test func readerRetriesAnIncompleteLastRecord() throws {
    let log = try makeRoutingLog([#"{"model":"complete"}"#])
    defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }
    let handle = try FileHandle(forWritingTo: log)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"model\":\"part".utf8))
    let reader = RoutingLogReader(url: log)
    #expect(reader.recentRecords().map(\.model) == ["complete"])
    try handle.write(contentsOf: Data("ial\"}".utf8))
    #expect(reader.recentRecords().map(\.model) == ["partial", "complete"])
}

@Test func readerBoundsTheTailAndPreservesUnicode() throws {
    let log = try makeRoutingLog([
        "{\"model\":\"" + String(repeating: "x", count: RoutingLogReader.tailByteLimit) + "\"}",
        #"{"model":"модель 🦊","ts":"2026-09-12T08:46:09.794Z"}"#,
        #"{"model":"次","ts":"2026-09-12T08:46:10Z"}"#,
    ])
    defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }
    let reader = RoutingLogReader(url: log)
    let records = reader.recentRecords()
    #expect(records.map(\.model) == ["次", "модель 🦊"])
    #expect(records.allSatisfy { $0.timestamp != nil })
    #expect(reader.recentRecords() == records)
}

@Test func readerPreservesExactKeysAndNormalizesNestedAliases() throws {
    let record = try #require(RoutingLogReader.record(from:
        #"{"model":"exact","Model":"alias","usage":{"Input-Tokens":41,"Output_Tokens":9},"meta":{"Selected_Target":"docs","TimeStamp":"2026-09-12T08:46:09+02:00"}}"#,
        id: 0))
    #expect(record.model == "exact")
    #expect(record.tier == "docs")
    #expect(record.tokens.total == 50)
    #expect(record.timestamp == ISO8601DateFormatter().date(from: "2026-09-12T06:46:09Z"))
}

@Test func readerCanBeSharedByConcurrentRefreshes() async throws {
    let log = try makeRoutingLog((0..<30).map { "{\"model\":\"m\($0)\"}" })
    defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }
    let reader = RoutingLogReader(url: log)
    await withTaskGroup(of: [RoutingLogRecord].self) { group in
        for _ in 0..<8 { group.addTask { reader.recentRecords() } }
        for await records in group {
            #expect(records.count == 30)
            #expect(records.first?.model == "m29")
        }
    }
}
