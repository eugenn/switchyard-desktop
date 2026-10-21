import Foundation
import Testing
@testable import SwitchyardDesktopKit

private let sessionNow = Date(timeIntervalSince1970: 1_789_000_000)

private func sessionRecord(
    id: Int,
    minutesAgo: Double,
    model: String,
    session: String,
    tier: String? = nil,
    origin: String? = "codex-cli",
    total: Int = 1_000
) -> RoutingLogRecord {
    RoutingLogRecord(
        id: id,
        timestamp: sessionNow.addingTimeInterval(-minutesAgo * 60),
        model: model,
        tier: tier,
        task: nil,
        origin: origin,
        sessionID: session,
        route: "switchyard-desktop",
        algorithm: "llm_task_classifier",
        tokens: RoutingLogRecord.Tokens(
            prompt: total, cached: 0, cacheCreation: 0, completion: 0, reasoning: 0, total: total
        ),
        fields: []
    )
}

/// Newest first, the way `RoutingLogReader` hands records back.
private let sessionRecords = [
    sessionRecord(id: 0, minutesAgo: 1, model: "terra", session: "a"),
    sessionRecord(id: 1, minutesAgo: 2, model: "luna", session: "a", tier: "classifier"),
    sessionRecord(id: 2, minutesAgo: 3, model: "sol", session: "a"),
    sessionRecord(id: 3, minutesAgo: 9, model: "terra", session: "a"),
    sessionRecord(id: 4, minutesAgo: 30, model: "sol", session: "b"),
    sessionRecord(id: 5, minutesAgo: 34, model: "sol", session: "b"),
    // A record Switchyard wrote without a session id belongs to no conversation.
    sessionRecord(id: 6, minutesAgo: 40, model: "terra", session: ""),
]

@Test func sessionsGroupTheLogByConversation() {
    let sessions = RoutingSession.sessions(from: sessionRecords)

    #expect(sessions.map(\.id) == ["a", "b"])
    let first = sessions[0]
    #expect(first.turns == 3)
    #expect(first.classifierCalls == 1)
    #expect(first.tokens == 4_000)
    // Most recently used first, and the judge's model is not a served lane.
    #expect(first.models == ["terra", "sol"])
    #expect(first.origin == "codex-cli")
    #expect(first.startedAt == sessionNow.addingTimeInterval(-9 * 60))
    #expect(first.lastActivity == sessionNow.addingTimeInterval(-60))
    #expect(first.span?.duration == 480.0)
    #expect(first.shortID == "a")
}

@Test func sessionsIgnoreRecordsWithoutAnIdentity() {
    let sessions = RoutingSession.sessions(from: sessionRecords)

    #expect(sessions.count == 2)
    #expect(sessions.allSatisfy { !$0.id.isEmpty })
    #expect(sessions.reduce(0) { $0 + $1.turns } == 5)
}

@Test func sessionsSortByMostRecentActivity() {
    let sessions = RoutingSession.sessions(from: sessionRecords.reversed())

    #expect(sessions.map(\.id) == ["a", "b"])
}

@Test func metricsOverASessionSpanCoverEveryTurnItRouted() {
    let session = try! #require(RoutingSession.sessions(from: sessionRecords).first { $0.id == "b" })
    let records = sessionRecords.filter { $0.sessionID == "b" }

    // The session ended half an hour ago, so a trailing 15m window is empty...
    let windowed = RoutingMetrics.compute(records: records, range: .fifteenMinutes, now: sessionNow)
    #expect(windowed.count == 0)

    // ...while its own span reports both turns, and rates them per second of
    // the session rather than per second of a window it did not live in.
    let scoped = RoutingMetrics.compute(
        records: records, range: .fifteenMinutes, now: sessionNow, span: session.span
    )
    #expect(scoped.count == 2)
    #expect(scoped.windowStart == session.startedAt)
    #expect(scoped.windowEnd == session.lastActivity)
    #expect(scoped.requestsPerSecond == 2.0 / 240.0)
    #expect(scoped.shares.map(\.id) == ["sol"])
    #expect(scoped.shares[0].share == 1)
    #expect(scoped.secondsPerRequest == 120.0)
}

@Test func aSessionOfOneCallStillReportsAFiniteRate() {
    let record = sessionRecord(id: 0, minutesAgo: 5, model: "terra", session: "solo")
    let session = try! #require(RoutingSession.sessions(from: [record]).first)

    #expect(session.span?.duration == 0)
    let metrics = RoutingMetrics.compute(
        records: [record], range: .fifteenMinutes, now: sessionNow, span: session.span
    )
    #expect(metrics.count == 1)
    #expect(metrics.requestsPerSecond == 1)
    #expect(metrics.shares[0].share == 1)
}

@Test func codexNamingThreadsAreNotConversations() throws {
    func record(_ session: String, _ tier: String = "", origin: String = "codex-cli", id: Int) throws -> RoutingLogRecord {
        try #require(RoutingLogReader.record(
            from: #"{"ts":\#(id),"origin":"\#(origin)","session_id":"\#(session)","model":"m","tier":"\#(tier)"}"#, id: id))
    }
    let records = try [
        record("real", id: 1), record("real", id: 2),
        // One served turn and no rollout: the thread Codex opens to title a conversation.
        record("naming", "classifier", id: 3), record("naming", id: 4),
        // The same shape from another client is a conversation.
        record("other", origin: "claude-code", id: 5),
        // A judge call alone is a turn still in flight, not a naming thread.
        record("pending", "classifier", id: 6),
    ]
    let kept = RoutingMonitor.droppingHousekeepingThreads(from: records) { $0 == "real" }
    #expect(Set(kept.compactMap(\.sessionID)) == ["real", "other", "pending"])
    #expect(kept.count == 4)
}
