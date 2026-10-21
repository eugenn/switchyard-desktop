import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SwitchyardDesktopKit

/// Opt-in fixture rendering without starting routing or touching user settings.
@MainActor
@Test func renderRequestFlowContextForVisualReview() async throws {
    guard let output = ProcessInfo.processInfo.environment["SWITCHYARD_DESKTOP_RENDER_CONTEXT"] else { return }
    let now = Date(timeIntervalSince1970: 1_789_000_000)
    let ids = ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "custom-model"]
    let inputs = [70_000, 225_000, 266_000, 0, 40_000]
    let records = try ids.enumerated().map { index, id in
        try #require(RoutingLogReader.record(from: """
        {"ts":\(now.timeIntervalSince1970 - Double(index) * 20),"session_id":"session","model":"\(id)","prompt_tokens":\(inputs[index])}
        """, id: index))
    }
    let windows = Dictionary(uniqueKeysWithValues: ids.dropLast().map { ($0, 272_000) })
    let sessions = RoutingSession.sessions(from: records, names: ["session": "Improve the routing dashboard"])
    let metrics = RoutingMetrics.compute(records: records, range: .hour, assignments: ["idle-model": "Idle"], now: now)
    // The judge answering the newest call, so its leg is drawn with traffic
    // and in the middle of an exchange.
    let judgeCall = try #require(RoutingLogReader.record(from: """
    {"ts":\(now.timeIntervalSince1970 + 1),"session_id":"session","model":"gpt-5.6-luna","tier":"classifier","prompt_tokens":3000}
    """, id: ids.count))
    let judged = RoutingMetrics.compute(
        records: records + [judgeCall], range: .hour, assignments: ["idle-model": "Idle"], now: now
    )
    let session = try #require(sessions.first)
    // Roles across the effort ladder, plus one target that names no effort, so
    // the fixture shows every state of the row's left column.
    let roles: [String: FlowRole] = [
        "gpt-6-astra": FlowRole(name: "Investigative", effort: .xhigh),
        "gpt-5.6-terra": FlowRole(name: "Standard", effort: .medium),
        "gpt-5.6-sol": FlowRole(name: "Direct", effort: .low),
        "custom-model": FlowRole(name: "House style", effort: nil),
    ]
    // The last two are the moving states: tokens on the wire, and the wait
    // after them that used to freeze the map solid.
    let states: [(String, String?, RoutingSession?, Set<String>, Bool, Date, RoutingMetrics)] = [
        ("selected", "session", session, ["session"], false, now, metrics),
        // Nothing picked: the map follows the newest conversation.
        ("newest", nil, session, ["session"], false, now, metrics),
        // A conversation gone quiet loses its live dot but keeps the map.
        ("quiet", nil, session, [], false, now, metrics),
        ("live", nil, session, ["session"], true, now, metrics),
        ("waiting", nil, session, ["session"], true, now.addingTimeInterval(90), metrics),
        ("judging", nil, session, ["session"], true, now.addingTimeInterval(1), judged),
    ]
    for (name, selection, contextSession, activeSessionIDs, isRouting, asOf, metrics) in states {
        let view = RequestFlowView(
            metrics: metrics, modelIDs: ids, isRouting: isRouting, sessions: sessions, asOf: asOf,
            usesClassifier: true, classifierModelID: "gpt-5.6-luna",
            contextUsage: contextSession == nil
                ? [:]
                : ModelContextUsage.latest(records: records, sessionID: "session", contextWindows: windows),
            contextSession: contextSession, activeSessionIDs: activeSessionIDs,
            routeContextWindow: 128_000, roles: roles,
            selectedModelID: .constant(nil), selectedSessionID: .constant(selection)
        )
        .frame(width: 800)
        .padding(20)
        .background(RouterTheme.win)
        .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).appendingPathExtension("\(name).png"))
    }
}
