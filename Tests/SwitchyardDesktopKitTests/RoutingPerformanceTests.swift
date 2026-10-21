import Foundation
import Testing
@testable import SwitchyardDesktopKit

/// Opt in with SWITCHYARD_DESKTOP_BENCHMARK=1 swift test -c release --filter routingPerformance.
/// Timings are reported, never used as hardware-dependent pass/fail thresholds.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["SWITCHYARD_DESKTOP_BENCHMARK"] == "1"))
func routingPerformance() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("routing.jsonl")
    let timestamp = Date().addingTimeInterval(-60).formatted(.iso8601)
    let lines = (0..<500).map { index in
        """
        {"ts":"\(timestamp)","route_id":"switchyard-desktop","algorithm":"llm_task_classifier",\
        "task":null,"trial_id":null,"session_id":"s\(index)","model":"model-\(index % 3)",\
        "tier":"\(index % 5 == 0 ? "classifier" : "")","prompt_tokens":65411,\
        "cached_tokens":62720,"cache_creation_tokens":0,"completion_tokens":312,\
        "reasoning_tokens":121,"total_tokens":65723}
        """
    }
    try (lines.joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)
    let reader = RoutingLogReader(url: log)
    #expect(reader.recentRecords().count == 500)
    let clock = ContinuousClock()
    var checksum = 0
    func measure(_ label: String, iterations: Int, _ work: () throws -> Int) rethrows {
        let start = clock.now
        for _ in 0..<iterations { checksum += try work() }
        let elapsed = start.duration(to: clock.now)
        print("BENCHMARK \(label): \(elapsed) / \(iterations) iterations")
    }
    measure("unchanged log", iterations: 30) { reader.recentRecords().count }
    let handle = try FileHandle(forWritingTo: log)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try measure("append and read", iterations: 30) {
        try handle.write(contentsOf: Data((lines[0] + "\n").utf8))
        return reader.recentRecords().count
    }
    let records = reader.recentRecords()
    measure("metrics aggregation", iterations: 1_000) {
        RoutingMetrics.compute(records: records, range: .hour).count
    }
    let model = WizardModel(
        sessionStore: ActiveRoutingSessionStore(fileURL: directory.appendingPathComponent("session.json")),
        restoreSavedSetup: false
    )
    model.profile.tiers = (0..<3).map { TaskTier(name: "Role \($0)", summary: "", modelID: "model-\($0)") }
    let monitor = RoutingMonitor(model: model, logReader: reader)
    await monitor.refresh()
    // One frame of the flow map's token streams: six lanes' worth of tiles
    // placed the way the canvas places them, sixty times a second, through
    // pipes that all share one bore.
    let lanes = (0..<6).map { index in
        TokenStream.Lane(
            id: "model-\(index)",
            curve: TokenStream.Curve(
                start: CGPoint(x: 168, y: 150),
                control1: CGPoint(x: 430, y: 150),
                control2: CGPoint(x: 480, y: 40 + CGFloat(index) * 50),
                end: CGPoint(x: 700, y: 40 + CGFloat(index) * 50)
            ),
            tint: .green,
            share: [0.4, 0.25, 0.15, 0.1, 0.07, 0.03][index],
            spread: 5.5
        )
    }
    measure("token stream frame", iterations: 300) {
        var placed = 0
        for lane in lanes {
            for tile in 0..<lane.tileCount {
                placed += lane.tile(tile, at: Double(placed) / 1_000).bucket + 1
            }
        }
        return placed
    }
    measure("statistics view reads", iterations: 1_000) {
        monitor.metrics.count + monitor.activityMetrics.count + monitor.selectedModelMetrics.count
            + monitor.modelIDs.count + monitor.filteredRecords.count
    }
    #expect(checksum > 0)
}
