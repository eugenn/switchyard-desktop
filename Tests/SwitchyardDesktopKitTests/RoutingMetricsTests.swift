import Foundation
import Testing
@testable import SwitchyardDesktopKit

private let metricsNow = Date(timeIntervalSince1970: 1_789_000_000)

private func makeRecord(
    id: Int,
    minutesAgo: Double,
    model: String,
    tier: String? = nil,
    prompt: Int = 1_000,
    cached: Int = 400,
    completion: Int = 100,
    isDelegated: Bool = false,
    agentID: String? = nil,
    agentRole: String? = nil,
    subagentIdentityUnsupported: Bool = false
) -> RoutingLogRecord {
    RoutingLogRecord(
        id: id,
        timestamp: metricsNow.addingTimeInterval(-minutesAgo * 60),
        model: model,
        tier: tier,
        task: nil,
        origin: nil,
        sessionID: "sess_\(id)",
        agentID: agentID,
        parentAgentID: nil,
        isDelegated: isDelegated,
        agentKind: nil,
        agentRole: agentRole,
        subagentIdentityUnsupported: subagentIdentityUnsupported,
        route: "switchyard-desktop",
        algorithm: "llm_task_classifier",
        tokens: RoutingLogRecord.Tokens(
            prompt: prompt,
            cached: cached,
            cacheCreation: 0,
            completion: completion,
            reasoning: 0,
            total: prompt + completion
        ),
        fields: []
    )
}

private let windowRecords = [
    makeRecord(id: 0, minutesAgo: 2, model: "gpt-terra"),
    makeRecord(id: 1, minutesAgo: 8, model: "gpt-terra"),
    makeRecord(id: 2, minutesAgo: 20, model: "gpt-sol"),
    makeRecord(id: 3, minutesAgo: 40, model: "gpt-sol"),
    // Outside a one-hour window.
    makeRecord(id: 4, minutesAgo: 180, model: "gpt-spark"),
]

@Test func metricsCountOnlyTheSelectedWindow() {
    let metrics = RoutingMetrics.compute(records: windowRecords, range: .hour, now: metricsNow)

    #expect(metrics.count == 4)
    #expect(metrics.requestsPerSecond == 4.0 / 3_600)
    #expect(metrics.tokens == 4 * 1_100)
    #expect(metrics.cachedTokens == 4 * 400)
}

@Test func sharesKeepTheSizeOfRecentCallsForTheFlowMap() {
    let sizes = [900, 4_000, 250]
    let records = sizes.enumerated().map { index, prompt in
        makeRecord(id: index, minutesAgo: Double(3 - index), model: "gpt-terra", prompt: prompt, completion: 100)
    }
    let share = try! #require(
        RoutingMetrics.compute(records: records, range: .hour, now: metricsNow).shares.first
    )
    // Oldest first, each call's own total, so a tile can be sized by the call
    // it stands for rather than by the lane's average.
    #expect(share.recentTokens == sizes.map { $0 + 100 })

    // A long-lived window keeps only the tail: this feeds a drawing.
    let many = (0..<(RoutingMetrics.recentTokenSamples + 20)).map {
        makeRecord(id: $0, minutesAgo: Double(60 - $0), model: "gpt-terra", prompt: 100 + $0, completion: 0)
    }
    let busy = try! #require(
        RoutingMetrics.compute(records: many, range: .hour, now: metricsNow).shares.first
    )
    #expect(busy.recentTokens.count == RoutingMetrics.recentTokenSamples)
    #expect(busy.recentTokens.last == 100 + many.count - 1)
}

@Test func metricsKeepAssignedButIdleModelsVisible() {
    let metrics = RoutingMetrics.compute(
        records: windowRecords,
        range: .hour,
        assignments: ["gpt-terra": "Architecture", "gpt-sol": "Refactors", "gpt-luna": "Long context"],
        now: metricsNow
    )

    #expect(metrics.shares.count == 3)
    let idle = metrics.shares.first { $0.id == "gpt-luna" }
    #expect(idle?.count == 0)
    #expect(idle?.share == 0)
    #expect(idle?.target == "Long context")

    let architecture = metrics.shares.first { $0.id == "gpt-terra" }
    #expect(architecture?.count == 2)
    #expect(architecture?.share == 0.5)
    #expect(architecture?.tokens == 2_200)
    // Switchyard leaves `tier` empty for a served turn, so the role comes from
    // the profile's own assignment.
    #expect(architecture?.target == "Architecture")
    // Ties break on the model id, and idle rows sort last.
    #expect(metrics.shares.map(\.id) == ["gpt-sol", "gpt-terra", "gpt-luna"])
}

/// An algorithm that does record its selected tier keeps it.
@Test func aRecordedTierNamesTheRoleItself() {
    let tiered = makeRecord(id: 5, minutesAgo: 1, model: "gpt-terra", tier: "architecture")
    let metrics = RoutingMetrics.compute(records: [tiered], range: .hour, now: metricsNow)

    #expect(metrics.shares.first?.target == "architecture")
}

@Test func metricsBucketTheWindowAndCountEveryTurn() {
    let metrics = RoutingMetrics.compute(
        records: windowRecords, range: .hour, now: metricsNow, bucketCount: 6
    )

    #expect(metrics.buckets.count == 6)
    #expect(metrics.buckets.map(\.count).reduce(0, +) == 4)
    #expect(metrics.buckets.map(\.tokens).reduce(0, +) == 4 * 1_100)
    #expect(metrics.buckets[0].start == metrics.windowStart)
}

@Test func metricsCountUntimestampedRecordsBecauseOnlyTheTailIsRead() {
    let untimed = RoutingLogRecord(
        id: 9, timestamp: nil, model: "gpt-spark", tier: nil, task: nil, origin: nil,
        sessionID: nil, agentID: nil, parentAgentID: nil, isDelegated: false, agentKind: nil,
        agentRole: nil, subagentIdentityUnsupported: false,
        route: nil, algorithm: nil, tokens: RoutingLogRecord.Tokens(), fields: []
    )

    let metrics = RoutingMetrics.compute(records: [untimed], range: .hour, now: metricsNow)

    #expect(metrics.count == 1)
    #expect(metrics.buckets.allSatisfy { $0.count == 0 })
}

@Test func emptyMetricsReportNothingWithoutFabricatingARate() {
    let metrics = RoutingMetrics.empty(range: .fifteenMinutes, now: metricsNow)

    #expect(metrics.isEmpty)
    #expect(metrics.requestsPerSecond == 0)
    #expect(metrics.tokens == 0)
    #expect(metrics.secondsPerRequest == nil)
    #expect(metrics.shares.isEmpty)
}

/// A judge call is paid routing overhead, not a served turn.
@Test func requestFlowExcludesInternalClassifierUsage() {
    let classifier = makeRecord(
        id: 7, minutesAgo: 1, model: "gpt-judge", tier: "classifier",
        prompt: 3_000, cached: 0, completion: 40
    )
    let metrics = RoutingMetrics.compute(
        records: windowRecords + [classifier], range: .hour, now: metricsNow
    )

    #expect(metrics.count == 4)
    #expect(!metrics.shares.contains { $0.id == "gpt-judge" })
    #expect(metrics.tokens == 4 * 1_100)
    #expect(metrics.classifierCount == 1)
    #expect(metrics.classifierTokens == 3_040)
}

/// The flow map draws the judge on a lane of its own, so the judge's own calls
/// must be summarised apart from the served-turn shares rather than dropped.
@Test func classifierSharesSummariseJudgeCallsOnTheirOwn() {
    let judgeCalls = [
        makeRecord(id: 7, minutesAgo: 1, model: "gpt-judge", tier: "classifier",
                   prompt: 3_000, cached: 0, completion: 40),
        makeRecord(id: 8, minutesAgo: 6, model: "gpt-judge", tier: "classifier",
                   prompt: 3_000, cached: 0, completion: 40),
    ]
    let metrics = RoutingMetrics.compute(
        records: windowRecords + judgeCalls, range: .hour, now: metricsNow
    )

    #expect(metrics.classifierShares.count == 1)
    let judge = try! #require(metrics.classifierShares.first)
    #expect(judge.id == "gpt-judge")
    #expect(judge.count == 2)
    // Of the judge calls alone, never of the four served turns.
    #expect(judge.share == 1)
    #expect(judge.requestsPerSecond == 2.0 / 3_600)
    #expect(!metrics.shares.contains { $0.id == "gpt-judge" })
}

@Test func latestNamesTheNewestCallInTheWindow() {
    let metrics = RoutingMetrics.compute(records: windowRecords, range: .hour, now: metricsNow)
    let latest = try! #require(metrics.latest)

    #expect(latest.modelID == "gpt-terra")
    #expect(!latest.isClassifier)
    #expect(latest.at == metricsNow.addingTimeInterval(-2 * 60))
}

/// A judge call is the newest thing that happened, so the map lights the judge
/// leg rather than a model lane.
@Test func latestReportsAJudgeCallAsTheClassifierLeg() {
    let judge = makeRecord(id: 9, minutesAgo: 0.5, model: "gpt-judge", tier: "classifier")
    let metrics = RoutingMetrics.compute(
        records: windowRecords + [judge], range: .hour, now: metricsNow
    )
    let latest = try! #require(metrics.latest)

    #expect(latest.modelID == "gpt-judge")
    #expect(latest.isClassifier)
    #expect(latest.at == metricsNow.addingTimeInterval(-0.5 * 60))
}

@Test func subagentMetricsSummariseDelegatedTraffic() {
    let subagentCalls = [
        makeRecord(id: 10, minutesAgo: 3, model: "gpt-sol", prompt: 500, completion: 50, isDelegated: true, agentID: "sub-1", agentRole: "researcher"),
        makeRecord(id: 11, minutesAgo: 5, model: "gpt-sol", prompt: 800, completion: 80, isDelegated: true, agentID: "sub-2", agentRole: "coder"),
        makeRecord(id: 12, minutesAgo: 7, model: "gpt-terra", prompt: 600, completion: 60, isDelegated: true, agentID: "sub-1", agentRole: "researcher"),
    ]
    let allRecords = windowRecords + subagentCalls
    let metrics = RoutingMetrics.compute(records: allRecords, range: .hour, now: metricsNow)

    #expect(metrics.count == 7) // 4 parent + 3 delegated
    #expect(metrics.delegatedCount == 3)
    #expect(metrics.delegatedTokens == 550 + 880 + 660)
    #expect(metrics.hasSubagentTraffic)
    #expect(metrics.uniqueSubagentsCount == 2)
    #expect(metrics.subagentRoles["researcher"] == 2)
    #expect(metrics.subagentRoles["coder"] == 1)

    // Check share breakdown
    let solShare = try! #require(metrics.shares.first { $0.id == "gpt-sol" })
    #expect(solShare.count == 4) // 2 parent + 2 delegated
    #expect(solShare.parentCount == 2)
    #expect(solShare.delegatedCount == 2)
    #expect(solShare.delegatedRatio == 0.5)

    let terraShare = try! #require(metrics.shares.first { $0.id == "gpt-terra" })
    #expect(terraShare.count == 3) // 2 parent + 1 delegated
    #expect(terraShare.parentCount == 2)
    #expect(terraShare.delegatedCount == 1)

    // Check delegatedShares
    #expect(metrics.delegatedShares.count == 2)
    let delegatedSol = try! #require(metrics.delegatedShares.first { $0.id == "gpt-sol" })
    #expect(delegatedSol.count == 2)
    #expect(delegatedSol.tokens == 550 + 880)
}

@Test func subagentIdentityUnsupportedFlagIsDetected() {
    let warningRecord = makeRecord(
        id: 15, minutesAgo: 4, model: "gpt-sol", prompt: 500, completion: 50,
        isDelegated: true, subagentIdentityUnsupported: true
    )
    let metrics = RoutingMetrics.compute(records: [warningRecord], range: .hour, now: metricsNow)
    #expect(metrics.subagentIdentityUnsupported)
}
