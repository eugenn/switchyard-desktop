import Foundation
import Testing
@testable import SwitchyardDesktopKit

/// Shaped like the payload `switchyard-server` returns on `GET /v1/stats`.
private func statsPayload() -> [String: Any] {
    [
    "total_requests": 81,
    "total_errors": 2,
    "total_tokens": [
        "prompt": 12_840,
        "completion": 3_420,
        "cached": 512,
        "cache_creation": 0,
        "reasoning": 96,
        "total": 16_868,
    ],
    "models": [
        "gpt-5.6-terra": ["requests": 53, "errors": 1, "tokens": ["total": 9_000]],
        "gpt-5.6-sol": ["requests": 20, "errors": 0, "tokens": ["total": 5_000]],
    ],
    "routing_overhead": [
        "count": 81, "total_ms": 900.0, "min_ms": 1.0, "max_ms": 42.0,
        "avg_ms": 11.1, "p50_ms": 10.8, "p99_ms": 38.0,
    ],
    "routing_fallbacks": ["context_window": 0, "unavailable": 3],
    "classifier": [
        "total_requests": 27,
        "total_errors": 1,
        "total_tokens": ["total": 2_400],
    ],
    "algorithm_stats": [
        "llm_classifier": [
            "routing_decisions": ["architecture": 40, "refactors": 20, "docs": 0]
        ]
        ],
    ]
}

@Test func statsDecodeReadsTheCountersTheStatisticsPaneShows() {
    let stats = SwitchyardStatsClient.decode(statsPayload())

    #expect(stats.totalRequests == 81)
    #expect(stats.totalErrors == 2)
    #expect(stats.tokens.prompt == 12_840)
    #expect(stats.tokens.completion == 3_420)
    #expect(stats.tokens.cached == 512)
    #expect(stats.tokens.total == 16_868)
    #expect(stats.classifierRequests == 27)
    #expect(stats.classifierErrors == 1)
    #expect(stats.overhead.p50Milliseconds == 10.8)
    #expect(stats.overhead.p99Milliseconds == 38.0)
    #expect(stats.overhead.maximumMilliseconds == 42.0)
}

@Test func statsDecodeSortsModelsByTrafficAndKeepsTheirTokens() {
    let stats = SwitchyardStatsClient.decode(statsPayload())

    #expect(stats.models.map(\.id) == ["gpt-5.6-terra", "gpt-5.6-sol"])
    #expect(stats.models.first?.requests == 53)
    #expect(stats.models.first?.errors == 1)
    #expect(stats.models.first?.tokens == 9_000)
}

@Test func statsDecodeDropsZeroedFallbacksAndDecisions() {
    let stats = SwitchyardStatsClient.decode(statsPayload())

    #expect(stats.fallbacks == ["unavailable": 3])
    #expect(stats.totalFallbacks == 3)
    #expect(stats.algorithm == "llm_classifier")
    #expect(stats.routingDecisions == ["architecture": 40, "refactors": 20])
}

@Test func statsDecodeTreatsAFreshProxyAsAllZeros() {
    let stats = SwitchyardStatsClient.decode([
        "total_requests": 0,
        "total_errors": 0,
        "models": [String: Any](),
        "algorithm_stats": ["stage_router": ["routing_decisions": [String: Any]()]],
    ])

    #expect(stats.totalRequests == 0)
    #expect(stats.models.isEmpty)
    #expect(stats.tokens.total == 0)
    #expect(stats.routingDecisions.isEmpty)
    #expect(stats.algorithm == "stage_router")
    #expect(stats.totalFallbacks == 0)
}

@Test func statsDecodeIgnoresFieldsItDoesNotUnderstand() {
    let stats = SwitchyardStatsClient.decode([
        "total_requests": 5,
        "something_new": ["nested": true],
    ])

    #expect(stats.totalRequests == 5)
    #expect(stats.totalErrors == 0)
}

@Test func statsDecodeBundledServerCallsAndTerminalLatency() {
    let stats = SwitchyardStatsClient.decode([
        "models": [
            "gpt-6-astra": [
                "calls": 7, "errors": 1, "total_tokens": 920,
                "total_latency": ["count": 6, "p50_ms": 1_200.5, "p99_ms": 9_000.0],
            ],
            "idle": ["calls": 0, "total_latency": ["count": 0, "p50_ms": 0, "p99_ms": 0]],
        ],
    ])
    #expect(stats.models.first?.requests == 7)
    #expect(stats.models.first?.tokens == 920)
    #expect(stats.models.first?.latency?.p50Milliseconds == 1_200.5)
    #expect(stats.models.first?.latency?.p99Milliseconds == 9_000)
    #expect(stats.models.last?.latency == nil)
}
