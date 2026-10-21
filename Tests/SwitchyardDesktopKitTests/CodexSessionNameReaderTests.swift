import Foundation
import Testing
@testable import SwitchyardDesktopKit

private func makeIndex(_ lines: [String]) throws -> (URL, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("session_index.jsonl")
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    return (directory, url)
}

@Test func sessionNamesComeFromTheIndexCodexKeeps() throws {
    let (directory, url) = try makeIndex([
        #"{"id":"a","thread_name":"Fix the release script","updated_at":"2026-09-15T09:00:00Z"}"#,
        #"{"id":"b","thread_name":"Улучшить читаемость интерфейса","updated_at":"2026-09-15T10:00:00Z"}"#,
        // A rename Codex appended later wins over the first name.
        #"{"id":"a","thread_name":"Cut the 0.4 release","updated_at":"2026-09-16T08:00:00Z"}"#,
        // Lines this app does not recognise never break the rest.
        "not json",
        #"{"thread_name":"no id"}"#,
        #"{"id":"c","thread_name":"   "}"#,
    ])
    defer { try? FileManager.default.removeItem(at: directory) }

    let names = CodexSessionNameReader(url: url).names()

    #expect(names["a"] == "Cut the 0.4 release")
    #expect(names["b"] == "Улучшить читаемость интерфейса")
    #expect(names["c"] == nil)
    #expect(names.count == 2)
}

@Test func anAbsentIndexLeavesEverySessionUnnamed() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let reader = CodexSessionNameReader(url: directory.appendingPathComponent("session_index.jsonl"))

    #expect(reader.names().isEmpty)
}

@Test func theIndexIsReadBesideTheCodexConfigItBelongsTo() {
    let config = URL(fileURLWithPath: "/tmp/codex-home/config.toml")

    #expect(
        CodexSessionNameReader.indexURL(configPath: config).path
            == "/tmp/codex-home/session_index.jsonl"
    )
}

@Test func aSessionIsNamedByItsIdUntilCodexNamesIt() {
    let record = RoutingLogRecord(
        id: 0, timestamp: Date(), model: "terra", tier: nil, task: nil, origin: nil,
        sessionID: "01a0a5b0-ded3-7331-bd06-eb76c5880a40", route: nil, algorithm: nil,
        tokens: RoutingLogRecord.Tokens(), fields: []
    )

    let unnamed = try! #require(RoutingSession.sessions(from: [record]).first)
    #expect(unnamed.title == "Session 880a40")
    #expect(unnamed.shortTitle == "Session 880a40")

    let named = try! #require(
        RoutingSession.sessions(
            from: [record],
            names: [
                "01a0a5b0-ded3-7331-bd06-eb76c5880a40":
                    "Протянуть фильтр сессий на список запросов",
            ]
        ).first
    )
    #expect(named.title == "Протянуть фильтр сессий на список запросов")
    // A long thread name is trimmed where it has to share a row.
    #expect(named.shortTitle.count == 34)
    #expect(named.shortTitle.hasSuffix("…"))
}
