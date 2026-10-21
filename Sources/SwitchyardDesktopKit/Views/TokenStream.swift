import SwiftUI

/// Shared routing-lane geometry and deterministic token-layout calculations.
/// Flow maps use the lane geometry only: active ribbons pulse as a whole,
/// without rendering individual tokens.
package enum TokenStream {
    /// Activity controls the active path's pulse and its card's shimmer.
    package enum Activity: Equatable, Sendable {
        /// Recent traffic: the active path pulses at the normal pace.
        case streaming
        /// Routing is on and nothing is moving — the model is thinking, or the
        /// next turn has not been sent.
        case thinking
        /// Nothing is routing.
        case idle
    }

    /// Tiles the whole map may draw, shared out between lanes by their share
    /// of the traffic. Sized so a full map stays well inside one frame's
    /// budget at 60 Hz on the slowest Mac the app supports.
    package static let budget = 300

    /// The fewest tiles a lane with any traffic at all gets, so a rounding
    /// error cannot leave a live lane looking dead.
    package static let minimumTiles = 6
    package static let maximumTiles = 96

    /// How fast a streak travels, in points a second. It is the same on every
    /// lane, so a short judge leg does not crawl while a long one races -- and
    /// slow enough that the eye can follow one streak the whole way.
    package static let travelSpeed: Double = 58

    /// A crossing never finishes quicker than this, however short the leg, so
    /// the shortest lane on the map still reads as a flow rather than a flicker.
    package static let minimumCrossing: Double = 1.6

    /// How brightly a pipe carrying `share` of the traffic reads, 0...1.
    ///
    /// Every pipe has the same bore, so usage is carried by brightness alone;
    /// the square root keeps a small share visible while stopping a dominant
    /// one from washing the rest of the map out.
    package static func prominence(share: Double) -> Double {
        min(1, max(0, share).squareRoot() * 1.15)
    }

    /// How far a tile may be scaled by the size of the call it stands for. A
    /// single enormous prompt should read as heavy without swallowing the lane.
    package static let weightRange: ClosedRange<Double> = 0.62...1.9

    /// A call's tile scale against the map's typical call. The side is the
    /// square root of the ratio because what the eye reads is the tile's area,
    /// so twice the area — not twice the side — means twice the tokens.
    package static func weight(tokens: Int, typical: Double) -> Double {
        guard tokens > 0, typical > 0 else { return 1 }
        return min(max((Double(tokens) / typical).squareRoot(), weightRange.lowerBound), weightRange.upperBound)
    }

    /// A recent call's normalized weight and delegation status.
    package struct CallWeight: Equatable, Sendable {
        package var weight: Double
        package var isDelegated: Bool

        package init(weight: Double, isDelegated: Bool = false) {
            self.weight = weight
            self.isDelegated = isDelegated
        }
    }

    /// A lane's curve, kept as control points rather than as a `Path` so the
    /// stroke and the tiles that ride it are laid out from one description.
    package struct Curve: Equatable {
        package let start: CGPoint
        package let control1: CGPoint
        package let control2: CGPoint
        package let end: CGPoint

        /// A straight leg, written as the cubic that has no bend.
        package init(from: CGPoint, to: CGPoint) {
            self.start = from
            self.end = to
            self.control1 = CGPoint(x: from.x + (to.x - from.x) / 3, y: from.y + (to.y - from.y) / 3)
            self.control2 = CGPoint(x: from.x + (to.x - from.x) * 2 / 3, y: from.y + (to.y - from.y) * 2 / 3)
        }

        package init(start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint) {
            self.start = start
            self.control1 = control1
            self.control2 = control2
            self.end = end
        }

        package var path: Path {
            Path { path in
                path.move(to: start)
                path.addCurve(to: end, control1: control1, control2: control2)
            }
        }

        package func point(at t: CGFloat) -> CGPoint {
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return CGPoint(
                x: a * start.x + b * control1.x + c * control2.x + d * end.x,
                y: a * start.y + b * control1.y + c * control2.y + d * end.y
            )
        }
    }

    /// One lane's flattened geometry and the traffic riding it.
    package struct Lane: Equatable, Identifiable {
        /// How many points a lane is flattened to. The tiles interpolate
        /// between neighbours, so this only has to be fine enough that a
        /// straight hop between samples stays on the curve.
        package static let sampleCount = 64

        package let id: String
        /// Evenly spaced along the curve, so a tile at phase `p` is simply the
        /// sample at `p * (count - 1)` and moves at a steady speed.
        package let points: [CGPoint]
        /// Unit normals at those samples, for the tile's offset off the centre
        /// line. Precomputed so a frame never takes a square root.
        package let normals: [CGVector]
        package let tint: Color
        /// 0...1 of the map's traffic: how many of the budget's tiles ride here.
        package let share: Double
        /// Half the pipe's bore, which is also how far a streak may sit off
        /// the centre line. Every pipe on a map shares it: what a lane carries
        /// is said by its `glow`, never by its width.
        package let spread: CGFloat
        /// Half the pipe's section where it meets the model. Equal to `spread`
        /// for a pipe of one bore; wider for a lane that flares out into the
        /// card it serves, so the stream docks along the card's whole edge
        /// instead of arriving at a point.
        package let endSpread: CGFloat
        /// The lane that carried the newest call rides brighter than the rest.
        package let isActive: Bool
        /// How long the lane is on screen, so a short leg is not packed with
        /// the tile count a long one earns from the same share.
        package let length: CGFloat
        /// Where this lane starts reading the noise table. Two lanes drawing
        /// the same tile numbers would otherwise carry the same pattern, which
        /// is plain to see when the map is idle and every stream is frozen.
        package let seed: Int
        /// One scale per recent call on this lane, oldest first: a tile is as
        /// big as the call it carries. Empty leaves every tile the same size.
        package let weights: [Double]
        package let callWeights: [CallWeight]
        package let delegatedRatio: Double

        package init(
            id: String,
            curve: Curve,
            tint: Color,
            share: Double,
            spread: CGFloat,
            endSpread: CGFloat? = nil,
            isActive: Bool = false,
            weights: [Double] = []
        ) {
            let (points, normals, length) = Lane.flatten(curve)
            self.id = id
            self.points = points
            self.normals = normals
            self.length = length
            self.seed = TokenStream.seed(for: id)
            self.tint = tint
            self.share = share
            self.spread = spread
            self.endSpread = endSpread ?? spread
            self.isActive = isActive
            self.weights = weights
            self.callWeights = weights.map { CallWeight(weight: $0, isDelegated: false) }
            self.delegatedRatio = 0
        }

        package init(
            id: String,
            curve: Curve,
            tint: Color,
            share: Double,
            spread: CGFloat,
            endSpread: CGFloat? = nil,
            isActive: Bool = false,
            callWeights: [CallWeight],
            delegatedRatio: Double = 0
        ) {
            let (points, normals, length) = Lane.flatten(curve)
            self.id = id
            self.points = points
            self.normals = normals
            self.length = length
            self.seed = TokenStream.seed(for: id)
            self.tint = tint
            self.share = share
            self.spread = spread
            self.endSpread = endSpread ?? spread
            self.isActive = isActive
            self.weights = callWeights.map(\.weight)
            self.callWeights = callWeights
            self.delegatedRatio = delegatedRatio
        }

        /// Walk the curve at a fine parameter step, measure it, then resample
        /// that measurement at an even arc length. Sampling the parameter
        /// alone would bunch tiles up wherever the curve turns.
        private static func flatten(_ curve: Curve) -> ([CGPoint], [CGVector], CGFloat) {
            let steps = 96
            var raw = [CGPoint]()
            raw.reserveCapacity(steps + 1)
            var lengths = [CGFloat]()
            lengths.reserveCapacity(steps + 1)
            var travelled: CGFloat = 0
            for step in 0...steps {
                let point = curve.point(at: CGFloat(step) / CGFloat(steps))
                if step > 0 {
                    travelled += hypot(point.x - raw[step - 1].x, point.y - raw[step - 1].y)
                }
                raw.append(point)
                lengths.append(travelled)
            }

            var points = [CGPoint]()
            points.reserveCapacity(sampleCount)
            guard travelled > 0 else {
                let flat = Array(repeating: curve.start, count: sampleCount)
                return (flat, Array(repeating: CGVector(dx: 0, dy: -1), count: sampleCount), 0)
            }
            var cursor = 0
            for index in 0..<sampleCount {
                let target = travelled * CGFloat(index) / CGFloat(sampleCount - 1)
                while cursor < steps - 1, lengths[cursor + 1] < target { cursor += 1 }
                let segment = lengths[cursor + 1] - lengths[cursor]
                let fraction = segment > 0 ? (target - lengths[cursor]) / segment : 0
                points.append(CGPoint(
                    x: raw[cursor].x + (raw[cursor + 1].x - raw[cursor].x) * fraction,
                    y: raw[cursor].y + (raw[cursor + 1].y - raw[cursor].y) * fraction
                ))
            }

            var normals = [CGVector]()
            normals.reserveCapacity(sampleCount)
            for index in 0..<sampleCount {
                let ahead = points[min(index + 1, sampleCount - 1)]
                let behind = points[max(index - 1, 0)]
                let dx = ahead.x - behind.x, dy = ahead.y - behind.y
                let length = max(hypot(dx, dy), 0.0001)
                normals.append(CGVector(dx: -dy / length, dy: dx / length))
            }
            return (points, normals, travelled)
        }

        /// Tiles are handed out by share of the traffic, then held back to
        /// what the lane has room for: a stream that fills its pipe solid
        /// stops reading as individual tokens, and pays for the privilege.
        package var tileCount: Int {
            guard share > 0 else { return 0 }
            let byShare = Int((Double(budget) * share).rounded())
            let byRoom = Int(length * max(spread, 1.2) / 28)
            return min(maximumTiles, max(minimumTiles, min(byShare, byRoom)))
        }

        /// How long one streak takes to travel this lane end to end, before
        /// its own small variance. Taken from the lane's length, so every
        /// streak on the map moves at the same speed.
        package var crossingSeconds: Double {
            max(Double(length) / TokenStream.travelSpeed, TokenStream.minimumCrossing)
        }

        /// This lane's brightness against the rest of the map.
        package var glow: Double { TokenStream.prominence(share: share) }

        /// How far a lane has opened `t` (0...1) of the way along it: barely
        /// at all over the first stretch, then more and more, levelling off
        /// just before the end so the flare meets its card square rather than
        /// at an angle. Squaring a smoothstep is what keeps the start slow.
        package static func flare(_ t: CGFloat) -> CGFloat {
            let t = min(max(t, 0), 1)
            let eased = t * t * (3 - 2 * t)
            return eased * eased
        }

        /// Half the pipe's section `t` of the way along it, running from the
        /// router's bore to `endHalfWidth` at the far end.
        package func halfWidth(at t: CGFloat, endHalfWidth: CGFloat? = nil) -> CGFloat {
            spread + ((endHalfWidth ?? endSpread) - spread) * Lane.flare(t)
        }

        /// The bed the tiles ride: the router's bore where it leaves the dock,
        /// opening out to `endWidth` at the model -- by default the lane's own
        /// `endSpread`, so a flared lane docks along its card's edge.
        ///
        /// Built from the same flattened lane the tiles use, once per layout.
        package func ribbon(endWidth: CGFloat? = nil) -> Path {
            subRibbon(fromSide: -1, toSide: 1, endWidth: endWidth)
        }

        /// A slice of the ribbon between `fromSide` and `toSide` (-1...1).
        /// Used to split ribbons into parent (upper) and delegated (lower) sub-bands.
        package func subRibbon(fromSide: CGFloat, toSide: CGFloat, endWidth: CGFloat? = nil) -> Path {
            var path = Path()
            let last = points.count - 1
            guard last > 0 else { return path }
            let endHalf = endWidth.map { $0 / 2 }

            func edge(_ index: Int, _ side: CGFloat) -> CGPoint {
                let width = halfWidth(at: CGFloat(index) / CGFloat(last), endHalfWidth: endHalf) * side
                return CGPoint(
                    x: points[index].x + normals[index].dx * width,
                    y: points[index].y + normals[index].dy * width
                )
            }

            path.move(to: edge(0, toSide))
            for index in 1...last { path.addLine(to: edge(index, toSide)) }
            for index in stride(from: last, through: 0, by: -1) { path.addLine(to: edge(index, fromSide)) }
            path.closeSubpath()
            return path
        }

        /// The lane's centre line, for a hairline down the middle of a tube.
        package func centerline() -> Path {
            var path = Path()
            guard let first = points.first else { return path }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            return path
        }

        /// A path tracing along the lane at a given `side` (-1...1).
        /// Used for dividing lines between parent and delegated sub-bands.
        package func boundary(side: CGFloat, endWidth: CGFloat? = nil) -> Path {
            var path = Path()
            let last = points.count - 1
            guard last > 0 else { return path }
            let endHalf = endWidth.map { $0 / 2 }

            func edge(_ index: Int) -> CGPoint {
                let width = halfWidth(at: CGFloat(index) / CGFloat(last), endHalfWidth: endHalf) * side
                return CGPoint(
                    x: points[index].x + normals[index].dx * width,
                    y: points[index].y + normals[index].dy * width
                )
            }

            path.move(to: edge(0))
            for index in 1...last { path.addLine(to: edge(index)) }
            return path
        }

        /// One particle or streak traveling along the lane.
        package struct Tile: Equatable {
            package let rect: CGRect
            package let bucket: Int
            package let isReturn: Bool
            package let tangent: CGVector
            package let isDelegated: Bool
        }

        /// Where one tile sits at `time`, and how brightly it is drawn.
        ///
        /// Odd indices stream forward (Router -> Model, prompt tokens).
        /// Even indices stream backward (Model -> Router, response tokens).
        package func tile(_ index: Int, at time: Double) -> Tile {
            let tiles = max(tileCount, 1)
            let key = index &+ seed
            let slot = (Double(index) + 0.85 * TokenStream.noise(key)) / Double(tiles)
            // Barely any variance: streaks that drift apart at different
            // speeds read as noise rather than as one flow down a pipe.
            let pace = 0.95 + 0.1 * TokenStream.noise(key &+ 211)
            let crossing = crossingSeconds / pace

            let isReturn = (index % 2 == 0)
            var phase: Double
            if isReturn {
                phase = slot - time / crossing
                phase = phase - phase.rounded(.down)
                if phase < 0 { phase += 1 }
            } else {
                phase = slot + time / crossing
                phase -= phase.rounded(.down)
            }

            let last = points.count - 1
            let position = phase * Double(last)
            let step = min(Int(position), last - 1)
            let fraction = position - Double(step)
            let here = points[step], next = points[step + 1]
            let normal = normals[step]
            let tangent = CGVector(dx: normal.dy, dy: -normal.dx)

            // A pipe of one bore draws its streaks together a little as they
            // reach the model; a flared one lets them spread out with it, so
            // the stream fills the mouth it docks into.
            let bore = endSpread == spread
                ? Double(spread) * (1 - 0.3 * phase)
                : Double(halfWidth(at: CGFloat(phase)))

            // Dual tracks: forward requests ride the upper track (+),
            // returning response tokens ride the lower track (-), preventing visual collisions.
            let trackSide: Double = isReturn ? -0.42 : 0.42
            let jitter = (TokenStream.noise(key &+ 97) * 2 - 1) * 0.32
            let offset = (trackSide + jitter) * bore

            let gauge = min(1, max(0.55, Double(spread) / 5))
            let weight: Double
            let isDelegated: Bool
            if !callWeights.isEmpty {
                let call = callWeights[key % callWeights.count]
                weight = call.weight
                isDelegated = call.isDelegated
            } else if !weights.isEmpty {
                weight = weights[key % weights.count]
                isDelegated = delegatedRatio > 0 && TokenStream.noise(key &+ 181) < delegatedRatio
            } else {
                weight = 0.8 + 0.5 * TokenStream.noise(key &+ 331)
                isDelegated = delegatedRatio > 0 && TokenStream.noise(key &+ 181) < delegatedRatio
            }
            let size = min(2.4 * weight * gauge, Double(spread) * 2 + 1.5)
            let x = here.x + (next.x - here.x) * fraction + normal.dx * offset
            let y = here.y + (next.y - here.y) * fraction + normal.dy * offset

            return Tile(
                rect: CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size),
                bucket: TokenStream.bucket(phase: phase, tile: key),
                isReturn: isReturn,
                tangent: tangent,
                isDelegated: isDelegated
            )
        }
    }

    /// Fixed noise. A tile reads its phase, speed, offset and size out of this
    /// by its own index, which keeps every tile stateless and every frame
    /// allocation-free — and keeps the stream identical across redraws.
    private static let noiseTable: [Double] = {
        var values = [Double]()
        values.reserveCapacity(512)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<512 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            mixed ^= mixed >> 31
            values.append(Double(mixed >> 40) / Double(1 << 24))
        }
        return values
    }()

    package static func noise(_ index: Int) -> Double { noiseTable[index & 511] }

    /// A lane's own offset into the table. Written out rather than taken from
    /// `hashValue`, which is seeded afresh every launch: a stream that came
    /// back different after a restart would look like a change in the data.
    package static func seed(for id: String) -> Int {
        var hash = 5_381
        for byte in id.utf8 { hash = (hash &* 33 &+ Int(byte)) & 511 }
        return hash
    }

    /// How brightly a tile is drawn, as an index into the legacy renderer's
    /// brightness buckets. Both ends of a lane fade, and the tiles in between
    /// come in two weights so a dense stream has texture rather than being a
    /// solid block of colour.
    package static let bucketCount = 4

    package static func bucket(phase: Double, tile: Int) -> Int {
        let edge = min(phase, 1 - phase)
        if edge < 0.04 { return 3 }
        if edge < 0.11 { return 2 }
        return noise(tile &+ 53) < 0.55 ? 0 : 1
    }
}
