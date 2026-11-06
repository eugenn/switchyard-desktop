import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SwitchyardDesktopKit

/// Opt-in render of the whole routing window from a fixture log, for visual
/// review. Writes `<output>.activity.png`, `<output>.overview.png` and
/// `<output>.requests.png`. Runs against a temporary log and session store, so
/// it never starts routing or reads the user's own data.
@MainActor
@Test func renderStatisticsWindowForVisualReview() async throws {
    guard let output = ProcessInfo.processInfo.environment["SWITCHYARD_DESKTOP_RENDER_STATISTICS"] else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let log = directory.appendingPathComponent("routing.jsonl")
    try fixtureLog(now: Date().timeIntervalSince1970).write(to: log, atomically: true, encoding: .utf8)

    let model = WizardModel(
        sessionStore: ActiveRoutingSessionStore(fileURL: directory.appendingPathComponent("session.json")),
        restoreSavedSetup: false
    )
    let roles = [
        RoutingRole(name: "Architectural", text: "Shape the system.", effort: .xhigh),
        RoutingRole(name: "Investigative", text: "Find the cause.", effort: .high),
        RoutingRole(name: "Direct", text: "Small edits.", effort: .medium),
        RoutingRole(name: "Standard", text: "Everyday work.", effort: .medium),
    ]
    model.profile.roles = [RoutingRole.builtInClassifier] + roles
    model.profile.tiers = zip(roles, ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna", "gpt-6-sol"]).map { role, id in
        var tier = TaskTier(name: role.name, summary: "", modelID: id)
        tier.roleID = role.id
        return tier
    }

    // Codex's model catalog and LiteLLM's price map, as fixtures, so the
    // context meters and the cost estimate show what they show in use.
    let ids = ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna", "gpt-6-sol"]
    let catalog = ["models": ids.map { ["slug": $0, "context_window": 872_000] }]
    try JSONSerialization.data(withJSONObject: catalog)
        .write(to: directory.appendingPathComponent("models_cache.json"))
    let prices = Dictionary(uniqueKeysWithValues: ids.map { id in
        (id, ["input_cost_per_token": 1.25e-06, "cache_read_input_token_cost": 1.25e-07, "output_cost_per_token": 1e-05])
    })
    let priceMap = directory.appendingPathComponent("prices.json")
    try JSONSerialization.data(withJSONObject: prices).write(to: priceMap)

    let monitor = RoutingMonitor(
        model: model, logReader: RoutingLogReader(url: log),
        modelContextReader: CodexModelContextReader(configPath: directory.appendingPathComponent("config.toml")),
        priceReader: ModelPriceReader(bundledURL: priceMap, cacheURL: nil, remoteURL: nil)
    )
    await monitor.refresh()
    // The proxy is not running here, so its counters come from a fixture too.
    func latency(_ p50: Double, _ p99: Double) -> [String: Any] { ["count": 20, "p50_ms": p50, "p99_ms": p99] }
    monitor.stats = SwitchyardStatsClient.decode([
        "total_requests": 138, "total_errors": 0,
        "models": [
            "gpt-6-luna": ["requests": 119, "errors": 0, "tokens": ["total": 0], "total_latency": latency(15_200, 80_300)],
            "gpt-6-sol": ["requests": 14, "errors": 0, "tokens": ["total": 0], "total_latency": latency(21_700, 58_400)],
            "gpt-6-astra": ["requests": 4, "errors": 0, "tokens": ["total": 0], "total_latency": latency(47_900, 66_000)],
            "gpt-6.1-sol": ["requests": 1, "errors": 0, "tokens": ["total": 0], "total_latency": latency(38_500, 38_500)],
        ],
    ])

    for pane in [RoutingMonitor.Pane.statistics, .overview, .requests] {
        monitor.pane = pane
        let hosting = NSHostingView(rootView: StatisticsWindow(monitor: monitor, openSetup: {}, showsStartControl: true))
        hosting.frame = NSRect(x: 0, y: 0, width: StatisticsWindow.windowWidth, height: StatisticsWindow.windowHeight)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let name = pane == .statistics ? "activity" : pane.rawValue
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).appendingPathExtension("\(name).png"))
    }
}

/// One 29-minute conversation: 69 served turns over four models, a judge call
/// before each, the newest turn on the busiest model.
private func fixtureLog(now: TimeInterval) throws -> String {
    var generator = SeededGenerator(seed: 7)
    let start = now - 29 * 60
    let plan: [(String, Int)] = [("gpt-6-astra", 4), ("gpt-6.1-sol", 1), ("gpt-6-sol", 14), ("gpt-6-luna", 50)]
    var turns: [(TimeInterval, String)] = []
    for (model, count) in plan {
        for _ in 0..<count {
            turns.append((start + Double.random(in: 30...(29 * 60 - 20), using: &generator), model))
        }
    }
    turns.sort { $0.0 < $1.0 }
    turns[turns.count - 1] = (now - 4, "gpt-6-luna")

    var lines: [[String: Any]] = []
    for (time, model) in turns {
        lines.append([
            "ts": time - 2, "session_id": "aee1e3", "model": "gpt-6-luna", "tier": "classifier",
            "prompt_tokens": 1_800, "total_tokens": 1_850,
        ])
        let prompt = Int.random(in: 60_000...170_000, using: &generator)
        lines.append([
            "ts": time, "session_id": "aee1e3", "model": model,
            "prompt_tokens": prompt, "cached_tokens": Int(Double(prompt) * 0.93),
            "completion_tokens": 1_200, "total_tokens": prompt + 1_200,
        ])
    }
    return try lines.map {
        String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
    }.joined(separator: "\n")
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
