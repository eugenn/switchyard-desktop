import Foundation
import SwiftUI
import Testing
@testable import SwitchyardDesktopKit

@MainActor
@Suite("Request flow activity")
struct RequestFlowActivityTests {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    private func metrics(latestModel: String, classifier: Bool = false) throws -> RoutingMetrics {
        let records = try ["older-a", "older-b", latestModel].enumerated().map { index, model in
            try #require(RoutingLogReader.record(from: """
            {"ts":\(now.timeIntervalSince1970 - Double(2 - index)),"model":"\(model)","tier":"\(classifier && index == 2 ? "classifier" : "")","total_tokens":1000}
            """, id: index))
        }
        return RoutingMetrics.compute(records: records, range: .hour, now: now)
    }

    private func pulse(
        metrics: RoutingMetrics, isRouting: Bool = true, selected: String? = nil, asOf: Date? = nil
    ) -> FlowPulseView {
        let view = RequestFlowView(
            metrics: metrics, modelIDs: metrics.shares.map(\.id), isRouting: isRouting,
            asOf: asOf ?? now, usesClassifier: true, selectedModelID: .constant(selected)
        )
        let lanes = view.tokenLanes(shares: metrics.shares, source: CGPoint(x: 168, y: 140), destinationX: 400)
        return view.pulseView(lanes: lanes, shares: metrics.shares)
    }

    @Test("Three used models produce only the newest model's pulse")
    func historicalTraffic() throws {
        let metrics = try metrics(latestModel: "current")
        #expect(metrics.shares.count == 3)
        #expect(metrics.shares.allSatisfy { $0.count > 0 })
        #expect(pulse(metrics: metrics).ribbons.map(\.id) == ["current"])
    }

    @Test("A newer routing check replaces the served-model pulse")
    func classifierTraffic() throws {
        let metrics = try metrics(latestModel: "older-a", classifier: true)
        #expect(metrics.classifierCount == 1)
        #expect(pulse(metrics: metrics).ribbons.map(\.id) == ["\u{0}classifier"])
    }

    @Test("Inspecting an old model never makes it active")
    func selectedHistoricalModel() throws {
        let metrics = try metrics(latestModel: "current")
        #expect(pulse(metrics: metrics, selected: "older-a").ribbons.isEmpty)
        #expect(pulse(metrics: metrics, selected: "current").ribbons.map(\.id) == ["current"])
    }

    @Test("Stopped routing and expired activity do not pulse")
    func stoppedAndExpired() throws {
        let metrics = try metrics(latestModel: "current")
        #expect(pulse(metrics: metrics, isRouting: false).ribbons.isEmpty)
        #expect(pulse(metrics: metrics, asOf: now.addingTimeInterval(601)).ribbons.isEmpty)
        #expect(pulse(metrics: metrics, asOf: now.addingTimeInterval(90)).ribbons.map(\.id) == ["current"])
    }
}
