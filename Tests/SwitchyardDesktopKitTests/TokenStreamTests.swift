import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SwitchyardDesktopKit

@Test func laneSamplesAreEvenlySpacedAlongTheCurve() {
    let lane = TokenStream.Lane(
        id: "lane",
        curve: TokenStream.Curve(
            start: CGPoint(x: 0, y: 0),
            control1: CGPoint(x: 200, y: 0),
            control2: CGPoint(x: 240, y: 300),
            end: CGPoint(x: 400, y: 300)
        ),
        tint: .green,
        share: 0.5,
        spread: 10
    )
    #expect(lane.points.count == TokenStream.Lane.sampleCount)
    #expect(lane.points.first == CGPoint(x: 0, y: 0))
    #expect(lane.points.last == CGPoint(x: 400, y: 300))

    // A tile moves by index, so uneven samples would make it speed up and slow
    // down wherever the lane turns.
    let gaps = (1..<lane.points.count).map {
        hypot(lane.points[$0].x - lane.points[$0 - 1].x, lane.points[$0].y - lane.points[$0 - 1].y)
    }
    let mean = gaps.reduce(0, +) / CGFloat(gaps.count)
    #expect(gaps.allSatisfy { abs($0 - mean) < mean * 0.05 })
    #expect(abs(lane.length - mean * CGFloat(gaps.count)) < 1)
}

@Test func laneNormalsAreUnitAndAcrossTheLane() {
    let lane = TokenStream.Lane(
        id: "flat", curve: TokenStream.Curve(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 300, y: 50)),
        tint: .green, share: 0.5, spread: 6
    )
    #expect(lane.normals.allSatisfy { abs(hypot($0.dx, $0.dy) - 1) < 0.001 })
    // A lane running right offsets its tiles straight up and down.
    #expect(lane.normals.allSatisfy { abs($0.dx) < 0.001 && abs(abs($0.dy) - 1) < 0.001 })
}

@Test func tileCountFollowsShareUntilTheLaneRunsOutOfRoom() {
    func lane(share: Double, spread: CGFloat, length: CGFloat) -> TokenStream.Lane {
        TokenStream.Lane(
            id: "lane", curve: TokenStream.Curve(from: .zero, to: CGPoint(x: length, y: 0)),
            tint: .green, share: share, spread: spread
        )
    }
    let busy = lane(share: 0.7, spread: 20, length: 600)
    let quiet = lane(share: 0.05, spread: 2, length: 600)
    #expect(busy.tileCount > quiet.tileCount)
    #expect(busy.tileCount <= TokenStream.maximumTiles)
    // A short judge leg keeps a readable stream instead of a solid bar.
    #expect(lane(share: 0.5, spread: 2.5, length: 30).tileCount == TokenStream.minimumTiles)
    #expect(lane(share: 0, spread: 20, length: 600).tileCount == 0)

    // Every pipe has the same bore now, so what a lane carries has to reach
    // the eye some other way: its glow.
    #expect(busy.glow > quiet.glow)
    #expect(lane(share: 0, spread: 20, length: 600).glow == 0)
    #expect(TokenStream.prominence(share: 1) == 1)
    #expect(TokenStream.prominence(share: -1) == 0)
}

@Test func tilesRideTheLaneAndStayInsideItsRibbon() {
    let spread: CGFloat = 12
    let lane = TokenStream.Lane(
        id: "lane",
        curve: TokenStream.Curve(
            start: CGPoint(x: 100, y: 100),
            control1: CGPoint(x: 300, y: 100),
            control2: CGPoint(x: 400, y: 260),
            end: CGPoint(x: 600, y: 260)
        ),
        tint: .green, share: 0.4, spread: spread, isActive: true
    )
    let room = spread + 4
    for time in stride(from: 0.0, to: 5.0, by: 0.25) {
        for index in 0..<lane.tileCount {
            let tile = lane.tile(index, at: time)
            #expect(tile.rect.midX >= 100 - room && tile.rect.midX <= 600 + room)
            #expect(tile.rect.midY >= 100 - room && tile.rect.midY <= 260 + room)
            #expect(tile.bucket >= 0 && tile.bucket < TokenStream.bucketCount)
            #expect(tile.rect.width > 0)
        }
    }

    // A tile travels, and comes back to where it started one crossing later.
    let start = lane.tile(3, at: 0).rect
    #expect(lane.tile(3, at: 0.4).rect != start)
    let pace = 0.95 + 0.1 * TokenStream.noise(3 + lane.seed + 211)
    let lap = lane.tile(3, at: lane.crossingSeconds / pace).rect
    #expect(abs(lap.midX - start.midX) < 0.001 && abs(lap.midY - start.midY) < 0.001)
}

/// Speed is the lane's length over one rate, so a short leg and a long one
/// move at the same pace on screen -- and slowly enough to follow.
@Test func everyLaneCarriesStreaksAtTheSameSpeed() {
    func lane(length: CGFloat) -> TokenStream.Lane {
        TokenStream.Lane(
            id: "lane", curve: TokenStream.Curve(from: .zero, to: CGPoint(x: length, y: 0)),
            tint: .green, share: 0.5, spread: 5.5
        )
    }
    let long = lane(length: 640), short = lane(length: 180)
    #expect(long.crossingSeconds > short.crossingSeconds)
    #expect(abs(Double(long.length) / long.crossingSeconds - TokenStream.travelSpeed) < 1)
    #expect(abs(Double(short.length) / short.crossingSeconds - TokenStream.travelSpeed) < 1)
    // A stub too short to earn the minimum crossing slows down rather than
    // flickering a streak across itself.
    #expect(lane(length: 30).crossingSeconds == TokenStream.minimumCrossing)
    // Slow enough that a streak stays on screen for seconds, not frames.
    #expect(long.crossingSeconds > 8)
}

@Test func tilesFunnelFromTheRouterIntoTheModel() {
    let lane = TokenStream.Lane(
        id: "lane", curve: TokenStream.Curve(from: CGPoint(x: 0, y: 100), to: CGPoint(x: 600, y: 100)),
        tint: .green, share: 0.6, spread: 20
    )
    // Sampling one tile across a crossing walks it the length of the lane, so
    // the near half and the far half describe the funnel the stream closes to.
    var near = 0.0, far = 0.0
    for step in 0..<200 {
        let rect = lane.tile(1, at: Double(step) * 0.01).rect
        let drift = abs(rect.midY - 100)
        if rect.midX < 300 { near = max(near, drift) } else { far = max(far, drift) }
    }
    #expect(near > far)

    // A pipe drawn to its own bore keeps that section the whole way, which is
    // what lets every lane dock against the router's edge side by side.
    let pipe = lane.ribbon(endWidth: lane.spread * 2)
    #expect(abs(pipe.boundingRect.height - 2 * lane.spread) < 0.001)
    #expect(pipe.boundingRect.minX <= 0.001 && pipe.boundingRect.maxX >= 599.999)
    // Asked for a narrower end, it still tapers: the judge stub uses that.
    #expect(lane.ribbon(endWidth: 4).boundingRect.height < 2 * lane.spread + 1)
}

@Test func aFlaredLaneOpensSlowlyAndDocksAlongItsCard() {
    let lane = TokenStream.Lane(
        id: "lane", curve: TokenStream.Curve(from: CGPoint(x: 0, y: 100), to: CGPoint(x: 600, y: 100)),
        tint: .green, share: 0.6, spread: 5, endSpread: 22
    )
    // It leaves the router at its bore and meets the card at the card's edge.
    #expect(abs(lane.halfWidth(at: 0) - 5) < 0.001)
    #expect(abs(lane.halfWidth(at: 1) - 22) < 0.001)
    #expect(abs(lane.ribbon().boundingRect.height - 44) < 0.001)
    // Slowly: most of the opening happens in the second half, and it levels
    // off before the card so the mouth meets the edge square.
    #expect(lane.halfWidth(at: 0.5) < (5 + 22) / 2)
    #expect(lane.halfWidth(at: 0.98) - lane.halfWidth(at: 0.96) < lane.halfWidth(at: 0.7) - lane.halfWidth(at: 0.68))
    for step in 1...20 {
        let t = CGFloat(step) / 20
        #expect(lane.halfWidth(at: t) >= lane.halfWidth(at: t - 0.05))
    }

    // The streaks spread out with the mouth rather than funnelling to a point.
    var near = 0.0, far = 0.0
    for step in 0..<400 {
        let rect = lane.tile(1, at: Double(step) * 0.05).rect
        let drift = abs(rect.midY - 100)
        #expect(drift <= 22 + 4)
        if rect.midX < 300 { near = max(near, drift) } else { far = max(far, drift) }
    }
    #expect(far > near)
}

@Test func aTileIsAsBigAsTheCallItCarries() {
    // Area, not side, is what the eye reads, so four times the tokens is twice
    // the tile — and one runaway prompt is held to the top of the range.
    #expect(TokenStream.weight(tokens: 40_000, typical: 40_000) == 1)
    #expect(abs(TokenStream.weight(tokens: 160_000, typical: 40_000) - 2) < 0.15)
    #expect(TokenStream.weight(tokens: 40_000_000, typical: 40_000) == TokenStream.weightRange.upperBound)
    #expect(TokenStream.weight(tokens: 1, typical: 40_000) == TokenStream.weightRange.lowerBound)
    // Nothing to measure against leaves the tile its ordinary size.
    #expect(TokenStream.weight(tokens: 0, typical: 40_000) == 1)
    #expect(TokenStream.weight(tokens: 4_000, typical: 0) == 1)

    func lane(_ weights: [Double]) -> TokenStream.Lane {
        TokenStream.Lane(
            id: "lane", curve: TokenStream.Curve(from: .zero, to: CGPoint(x: 400, y: 0)),
            tint: .green, share: 0.4, spread: 9, weights: weights
        )
    }
    let heavy = lane([TokenStream.weightRange.upperBound]).tile(0, at: 0).rect
    let light = lane([TokenStream.weightRange.lowerBound]).tile(0, at: 0).rect
    #expect(heavy.width > light.width * 2)
    // A lane with no per-call sizes still varies, but only as texture.
    let plain = lane([])
    #expect(plain.tile(0, at: 0).rect.width > 0)
}

@Test func lanesReadTheNoiseTableFromTheirOwnPlace() {
    func lane(_ id: String) -> TokenStream.Lane {
        TokenStream.Lane(
            id: id, curve: TokenStream.Curve(from: CGPoint(x: 0, y: 40), to: CGPoint(x: 400, y: 40)),
            tint: .green, share: 0.3, spread: 8
        )
    }
    // Two idle lanes freeze at the same instant, so an identical pattern would
    // read as a repeat rather than as two streams.
    #expect(lane("alpha").tile(0, at: 0).rect != lane("beta").tile(0, at: 0).rect)
    // The same lane is the same stream, restart after restart.
    #expect(TokenStream.seed(for: "alpha") == TokenStream.seed(for: "alpha"))
    #expect(lane("alpha").tile(4, at: 1.5).rect == lane("alpha").tile(4, at: 1.5).rect)
}

@Test func noiseIsStableAndBounded() {
    let sample = (0..<600).map(TokenStream.noise)
    #expect(sample.allSatisfy { $0 >= 0 && $0 < 1 })
    // Tiles keep their phase across redraws, and the table wraps by its size.
    #expect(sample == (0..<600).map(TokenStream.noise))
    #expect(TokenStream.noise(0) == TokenStream.noise(512))
    #expect(TokenStream.noise(0) != TokenStream.noise(1))
}

@Test func callWeightsReflectDelegationOnTiles() {
    let callWeights = [
        TokenStream.CallWeight(weight: 1.0, isDelegated: false),
        TokenStream.CallWeight(weight: 1.5, isDelegated: true),
    ]
    let lane = TokenStream.Lane(
        id: "sub-lane",
        curve: TokenStream.Curve(from: .zero, to: CGPoint(x: 400, y: 0)),
        tint: .green,
        share: 0.5,
        spread: 10,
        callWeights: callWeights,
        delegatedRatio: 0.5
    )
    var sawDelegated = false
    var sawParent = false
    for index in 0..<lane.tileCount {
        let tile = lane.tile(index, at: 0)
        if tile.isDelegated { sawDelegated = true } else { sawParent = true }
    }
    #expect(sawDelegated)
    #expect(sawParent)
}

@Test func subRibbonAndBoundaryProduceValidPaths() {
    let lane = TokenStream.Lane(
        id: "lane",
        curve: TokenStream.Curve(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 400, y: 50)),
        tint: .blue,
        share: 0.5,
        spread: 10
    )
    let parentBand = lane.subRibbon(fromSide: 0, toSide: 1, endWidth: 4)
    let subagentBand = lane.subRibbon(fromSide: -1, toSide: 0, endWidth: 4)
    let boundary = lane.boundary(side: 0, endWidth: 4)

    #expect(!parentBand.isEmpty)
    #expect(!subagentBand.isEmpty)
    #expect(!boundary.isEmpty)
    #expect(parentBand.boundingRect.maxY > subagentBand.boundingRect.minY)
}
