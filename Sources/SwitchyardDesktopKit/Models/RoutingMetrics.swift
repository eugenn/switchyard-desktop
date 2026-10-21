import Foundation

/// Windows the statistics pane can summarise.
package enum MetricsRange: String, CaseIterable, Identifiable, Sendable {
    case fifteenMinutes
    case hour
    case sixHours
    case day

    package var id: String { rawValue }

    package var label: String {
        switch self {
        case .fifteenMinutes: "15m"
        case .hour: "1h"
        case .sixHours: "6h"
        case .day: "24h"
        }
    }

    package var duration: TimeInterval {
        switch self {
        case .fifteenMinutes: 15 * 60
        case .hour: 60 * 60
        case .sixHours: 6 * 60 * 60
        case .day: 24 * 60 * 60
        }
    }

    package var name: String {
        switch self {
        case .fifteenMinutes: "last 15 minutes"
        case .hour: "last hour"
        case .sixHours: "last 6 hours"
        case .day: "last 24 hours"
        }
    }
}

/// What the statistics panes derive from the durable routing log: how many turns
/// each model served in a window, when they arrived, and what they cost in
/// tokens.
///
/// The log records token usage per call and nothing else — no latency, no HTTP
/// status. Latency and error counters come from the proxy's own `/v1/stats`
/// (`RoutingStats`), which reports them for the whole process lifetime rather
/// than for a window.
package struct RoutingMetrics: Equatable, Sendable {
    package struct Bucket: Equatable, Sendable, Identifiable {
        package let id: Int
        package let start: Date
        package let count: Int
        package let tokens: Int
    }

    package struct RecentCall: Equatable, Sendable {
        package let tokens: Int
        package let isDelegated: Bool
    }

    package struct Share: Equatable, Sendable, Identifiable {
        package let id: String
        package let target: String?
        package let count: Int
        /// 0...1 of the window's routed turns.
        package let share: Double
        package let requestsPerSecond: Double
        package let tokens: Int
        package let cachedTokens: Int
        /// What the last few calls on this model cost, newest last, so the flow
        /// map can size a tile by the call it stands for. Bounded: it feeds a
        /// drawing, not a report, and the report is `tokens`.
        package var recentTokens: [Int] = []
        package var parentCount: Int = 0
        package var delegatedCount: Int = 0
        package var delegatedTokens: Int = 0
        package var recentCalls: [RecentCall] = []

        package var delegatedRatio: Double {
            count > 0 ? Double(delegatedCount) / Double(count) : 0
        }
    }

    /// How many per-call token counts a share keeps for the flow map.
    package static let recentTokenSamples = 32

    /// The most recent call the window saw, judge calls included.
    package struct Latest: Equatable, Sendable {
        package let modelID: String
        package let isClassifier: Bool
        package let at: Date?
    }

    package let range: MetricsRange
    package let windowStart: Date
    package let windowEnd: Date
    package let count: Int
    package let requestsPerSecond: Double
    package let tokens: Int
    package let cachedTokens: Int
    package let buckets: [Bucket]
    package let shares: [Share]
    /// Judge calls in the window. They pay for routing and never serve a turn,
    /// so they are counted apart from `count`.
    package let classifierCount: Int
    package let classifierTokens: Int
    /// One row per judge model that was asked in the window. Their `share` is of
    /// the judge calls alone, never of the served turns.
    package let classifierShares: [Share]
    /// The newest call in the window, so the flow map can show which leg is
    /// carrying traffic right now.
    package let latest: Latest?

    /// Subagent metrics: calls delegated to subagents
    package let delegatedCount: Int
    package let delegatedTokens: Int
    /// Per-model shares of delegated traffic alone
    package let delegatedShares: [Share]
    /// Whether the client/harness failed to provide subagent identity
    package let subagentIdentityUnsupported: Bool
    /// Number of distinct subagent IDs observed in the window
    package let uniqueSubagentsCount: Int
    /// Breakdown of delegated calls by role/kind
    package let subagentRoles: [String: Int]

    package var isEmpty: Bool { count == 0 && classifierCount == 0 && delegatedCount == 0 }
    package var hasSubagentTraffic: Bool { delegatedCount > 0 }

    package var delegatedTokenRatio: Double {
        tokens > 0 ? Double(delegatedTokens) / Double(tokens) : 0
    }

    /// What the rates are per: the wall-clock range, or the span of the session
    /// the summary was narrowed to.
    package var windowDuration: TimeInterval {
        max(windowEnd.timeIntervalSince(windowStart), 1)
    }

    /// Seconds between routed turns, for the rate tile's own subtitle.
    package var secondsPerRequest: Double? {
        guard count > 1 else { return nil }
        return windowDuration / Double(count)
    }

    package static func empty(range: MetricsRange, now: Date = Date()) -> RoutingMetrics {
        RoutingMetrics(
            range: range,
            windowStart: now.addingTimeInterval(-range.duration),
            windowEnd: now,
            count: 0,
            requestsPerSecond: 0,
            tokens: 0,
            cachedTokens: 0,
            buckets: [],
            shares: [],
            classifierCount: 0,
            classifierTokens: 0,
            classifierShares: [],
            latest: nil,
            delegatedCount: 0,
            delegatedTokens: 0,
            delegatedShares: [],
            subagentIdentityUnsupported: false,
            uniqueSubagentsCount: 0,
            subagentRoles: [:]
        )
    }

    // MARK: - Computation

    /// `span` narrows the summary to a window the records themselves define —
    /// one session's lifetime — instead of the trailing wall-clock `range`.
    /// Rates are then per second of that span, so a short burst inside a long
    /// window is not diluted by time the session did not exist for.
    package static func compute(
        records: [RoutingLogRecord],
        range: MetricsRange,
        assignments: [String: String] = [:],
        now: Date = Date(),
        bucketCount: Int = 12,
        span: DateInterval? = nil
    ) -> RoutingMetrics {
        let start = span?.start ?? now.addingTimeInterval(-range.duration)
        let end = span?.end ?? now
        let duration = span.map { max($0.duration, 1) } ?? range.duration
        let futureLimit = end.addingTimeInterval(60)
        let count = max(0, bucketCount)
        let width = count > 0 ? max(end.timeIntervalSince(start), 1) / Double(count) : 0
        var bucketCounts = Array(repeating: 0, count: count)
        var bucketTokens = Array(repeating: 0, count: count)
        var served = Totals()
        var classifier = Totals()
        var delegated = Totals()
        var newest: RoutingLogRecord?
        var unsupportedIdentity = false
        var subagentIDs = Set<String>()
        var subagentRoles: [String: Int] = [:]

        // Aggregate once without allocating filtered record arrays, timestamp
        // tuples, or separate token/count dictionaries for every model.
        for record in records {
            if let timestamp = record.timestamp,
               timestamp < start || timestamp > futureLimit { continue }
            if let timestamp = record.timestamp {
                if newest?.timestamp.map({ timestamp > $0 }) ?? true { newest = record }
            } else if newest == nil {
                newest = record
            }
            if record.subagentIdentityUnsupported {
                unsupportedIdentity = true
            }
            if record.isClassifier {
                classifier.add(record)
            } else {
                served.add(record)
                if record.isDelegated {
                    delegated.add(record)
                    if let agentID = record.agentID, !agentID.isEmpty {
                        subagentIDs.insert(agentID)
                    }
                    let role = record.agentRole ?? record.agentKind ?? "subagent"
                    subagentRoles[role, default: 0] += 1
                }
                if count > 0, let timestamp = record.timestamp {
                    let offset = timestamp.timeIntervalSince(start) / width
                    let index = min(max(Int(offset), 0), count - 1)
                    bucketCounts[index] += 1
                    bucketTokens[index] += record.tokens.total
                }
            }
        }

        return RoutingMetrics(
            range: range,
            windowStart: start,
            windowEnd: end,
            count: served.count,
            requestsPerSecond: Double(served.count) / duration,
            tokens: served.tokens,
            cachedTokens: served.cachedTokens,
            buckets: (0..<count).map { index in
                Bucket(id: index, start: start.addingTimeInterval(width * Double(index)),
                       count: bucketCounts[index], tokens: bucketTokens[index])
            },
            shares: served.shares(duration: duration, assignments: assignments),
            classifierCount: classifier.count,
            classifierTokens: classifier.tokens,
            classifierShares: classifier.shares(duration: duration, assignments: [:]),
            latest: newest.map {
                Latest(modelID: $0.modelIdentity, isClassifier: $0.isClassifier, at: $0.timestamp)
            },
            delegatedCount: delegated.count,
            delegatedTokens: delegated.tokens,
            delegatedShares: delegated.shares(duration: duration, assignments: [:]),
            subagentIdentityUnsupported: unsupportedIdentity,
            uniqueSubagentsCount: subagentIDs.count,
            subagentRoles: subagentRoles
        )
    }

    private struct ModelTotals {
        package var count = 0
        package var tokens = 0
        package var cachedTokens = 0
        package var target: String?
        package var recentTokens: [Int] = []
        package var parentCount = 0
        package var delegatedCount = 0
        package var delegatedTokens = 0
        package var recentCalls: [RecentCall] = []

        package mutating func remember(_ volume: Int, isDelegated: Bool) {
            if recentTokens.count == RoutingMetrics.recentTokenSamples {
                recentTokens.removeFirst()
                recentCalls.removeFirst()
            }
            recentTokens.append(volume)
            recentCalls.append(RecentCall(tokens: volume, isDelegated: isDelegated))
        }
    }

    private struct Totals {
        package var count = 0
        package var tokens = 0
        package var cachedTokens = 0
        package var models: [String: ModelTotals] = [:]

        package mutating func add(_ record: RoutingLogRecord) {
            count += 1
            tokens += record.tokens.total
            cachedTokens += record.tokens.cached
            let model = record.modelIdentity
            var usage = models[model] ?? ModelTotals()
            usage.count += 1
            usage.tokens += record.tokens.total
            usage.cachedTokens += record.tokens.cached
            if record.isDelegated {
                usage.delegatedCount += 1
                usage.delegatedTokens += record.tokens.total
            } else {
                usage.parentCount += 1
            }
            // A call's own size. Switchyard reports a total once it knows one;
            // before then the prompt is all the call has weighed.
            let volume = record.tokens.total > 0 ? record.tokens.total : record.tokens.prompt
            usage.remember(volume, isDelegated: record.isDelegated)
            if let tier = record.tier, !tier.isEmpty { usage.target = tier }
            models[model] = usage
        }

        /// Include configured models with no turns so idle assignments stay visible.
        package func shares(duration: TimeInterval, assignments: [String: String]) -> [Share] {
            var models = models
            for (model, target) in assignments where models[model] == nil {
                models[model] = ModelTotals(target: target)
            }
            return models.map { model, usage in
                Share(
                    id: model,
                    target: usage.target ?? assignments[model],
                    count: usage.count,
                    share: count == 0 ? 0 : Double(usage.count) / Double(count),
                    requestsPerSecond: Double(usage.count) / duration,
                    tokens: usage.tokens,
                    cachedTokens: usage.cachedTokens,
                    recentTokens: usage.recentTokens,
                    parentCount: usage.parentCount,
                    delegatedCount: usage.delegatedCount,
                    delegatedTokens: usage.delegatedTokens,
                    recentCalls: usage.recentCalls
                )
            }.sorted {
                $0.count == $1.count ? $0.id < $1.id : $0.count > $1.count
            }
        }
    }
}
