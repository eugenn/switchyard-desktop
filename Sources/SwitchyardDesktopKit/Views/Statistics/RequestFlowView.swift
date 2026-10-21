import SwiftUI

/// Visualisation of live routing traffic: the switchyard-desktop on the left,
/// each configured model on the right, and bezier lanes connecting them.
///
/// Every lane is a translucent tube. They all leave the router card's right
/// edge from one point and fan out to their models, so where they overlap the
/// light stacks up; how much of the traffic a tube carries is in how thick it
/// is at the router and how brightly it glows. Each model's card sits in a
/// soft glow of its own colour, brightest for the model that served the most
/// recent request.
///
/// Also visualizes:
/// - Classifier calls on a distinct judge lane above the router.
/// - Delegated subagent calls: split ribbons separating parent and delegated
///   traffic, dashed outlines and subagent badges.
///
/// The active path softly pulses as a whole, without individual token particles.
package struct RequestFlowView: View {
    package let metrics: RoutingMetrics
    package let modelIDs: [String]
    package let isRouting: Bool
    package var sessions: [RoutingSession] = []
    package var asOf: Date?
    package var usesClassifier: Bool = false
    package var classifierModelID: String?
    package var contextUsage: [String: ModelContextUsage] = [:]
    /// The conversation the map shows: the picked one, or the newest.
    package var contextSession: RoutingSession?
    /// Conversations live right now, marked in the session picker.
    package var activeSessionIDs: Set<String> = []
    package var routeContextWindow: Int?
    /// The role each model serves, by model id. Empty for a route whose
    /// targets name no roles, which leaves the rows ordered by traffic.
    package var roles: [String: FlowRole] = [:]
    @Binding var selectedModelID: String?
    package var selectedSessionID: Binding<String?> = .constant(nil)

    /// Highlight stays "live" for this long after a request before settling
    /// back to the idle state.
    private static let liveWindow: TimeInterval = 8

    /// How long after the newest call the served role's card keeps shimmering
    /// instead of going still. A model can think for minutes before the next
    /// token appears, and a frozen card is indistinguishable from an app that
    /// has stopped responding -- but a window left open overnight should settle.
    private static let thinkingWindow: TimeInterval = 600

    private var showsClassifierLane: Bool { usesClassifier || !metrics.classifierShares.isEmpty }
    /// The effort column only earns its width once a role actually names a
    /// level; otherwise every row would carry the same empty mark.
    private var showsEffortLadder: Bool { roles.values.contains { $0.effort != nil } }
    /// The rows in the order the map draws them, top to bottom.
    private var orderedShares: [RoutingMetrics.Share] {
        FlowRole.ordered(metrics.shares, roles: roles)
    }
    private var showsContext: Bool { contextSession != nil }
    private var modelRowHeight: CGFloat { showsContext ? 64 : 58 }
    private var rowInset: CGFloat { modelRowHeight / 2 + 5 }

    /// Only as tall as the rows need: a two-model route left a third of the
    /// card empty at the old floor.
    private var chartHeight: CGFloat {
        max(showsClassifierLane ? 248 : 196, CGFloat(metrics.shares.count) * (modelRowHeight + 8) + 20)
    }

    private var sourceY: CGFloat {
        showsClassifierLane ? max(chartHeight / 2, 140) : chartHeight / 2
    }

    /// The judge model's own row, or the configured one before it has answered.
    private var classifierShare: RoutingMetrics.Share? { metrics.classifierShares.first }

    private var classifierLabel: String {
        classifierShare?.id ?? classifierModelID ?? "not assigned"
    }

    /// The leg that carried the newest call in the window. It stays highlighted
    /// after traffic stops; only `isLive` decides whether it also animates.
    private var latest: RoutingMetrics.Latest? { metrics.latest }

    private var isLive: Bool {
        guard isRouting, let latest else { return false }
        guard let at = latest.at else { return true }
        return (asOf ?? metrics.windowEnd).timeIntervalSince(at) <= Self.liveWindow
    }

    /// Routing is on and no tokens have moved lately: the model is thinking,
    /// or the next turn has not been sent yet. The served role's card keeps
    /// shimmering through the wait, so it never reads as a hung window -- but
    /// nothing on the pipes themselves moves, since nothing is actually
    /// travelling down them.
    private var isThinking: Bool {
        guard isRouting, !isLive, let at = latest?.at else { return false }
        return (asOf ?? metrics.windowEnd).timeIntervalSince(at) <= Self.thinkingWindow
    }

    private var activity: TokenStream.Activity {
        if isLive { return .streaming }
        return isThinking ? .thinking : .idle
    }

    /// Whether the served role's card should be shimmering: real traffic, or
    /// a wait the map is still signalling as alive.
    private var isAnimating: Bool { isLive || isThinking }

    /// What the widths and rates are measured over, named in the card's corner.
    private var windowLabel: String {
        guard let session = contextSession else { return "15m window" }
        guard let span = session.span, span.duration >= 1 else { return "one session" }
        return "session · \(Self.durationText(span.duration))"
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return "\(total / 60)m" }
        return "\(total / 3_600)h \((total % 3_600) / 60)m"
    }

    private func isActive(_ modelID: String) -> Bool {
        guard let latest, !latest.isClassifier else { return false }
        return latest.modelID == modelID
    }

    private var classifierIsActive: Bool { latest?.isClassifier == true }

    /// Where the judge card ends and its leg down to the router begins.
    private var classifierCardBottom: CGFloat { 42 + 33 }

    package var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Request flow")
                    .font(RouterTheme.sans(13, .semibold))
                    .foregroundStyle(RouterTheme.ink)
                Spacer()
                if let latest, isAnimating {
                    let tint = latest.isClassifier
                        ? ModelFlowPalette.judge
                        : ModelFlowPalette.color(for: latest.modelID, in: modelIDs)
                    let name = latest.isClassifier ? "classifier" : latest.modelID
                    // The chip names what the map is doing; the shimmer that
                    // says so lives on the served role's own card, not here,
                    // so this dot holds still while waiting.
                    LiveBadge(
                        tint: isLive ? tint : RouterTheme.ink3,
                        text: isLive ? name : "waiting",
                        blinks: isLive,
                        accessibilityText: isLive
                            ? nil
                            : "Routing is on and no tokens have moved since \(name) answered. The model may still be thinking."
                    )
                    .help(isLive
                          ? "Tokens are moving on \(name) right now."
                          : "Routing is on; nothing is on the wire since \(name) answered. \(name)'s card keeps shimmering while the map waits.")
                }
                if !sessions.isEmpty || isRouting {
                    SessionPicker(
                        sessions: sessions, selection: selectedSessionID,
                        activeSessionIDs: activeSessionIDs, allowsAll: false
                    )
                }
                Text(windowLabel)
                    .font(RouterTheme.mono(10.5))
                    .foregroundStyle(RouterTheme.ink3)
            }

            if metrics.subagentIdentityUnsupported {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(RouterTheme.warn)
                        .font(.system(size: 11))
                    Text("Harness does not send subagent identity; delegated requests route through parent.")
                        .font(RouterTheme.sans(11))
                        .foregroundStyle(RouterTheme.ink2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RouterTheme.warn.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(RouterTheme.warn.opacity(0.25)))
            }

            if metrics.shares.isEmpty {
                StatsEmptyState(
                    message: contextSession == nil
                        ? "Assign models in Routing config to see where requests go."
                        : "This session routed no turns the log could attribute to a model."
                )
            } else {
                GeometryReader { geometry in
                    let source = CGPoint(x: 168, y: sourceY)
                    let rowX = geometry.size.width - (Self.rowWidth + 6)
                    // Each lane runs on under its card's edge, so the flare
                    // and the card meet with no seam between them.
                    let destinationX = rowX + Self.dockTuck
                    // One lane per share that carried traffic, laid out once:
                    // the bed under the stream and the stream itself are the
                    // same flattened curve.
                    let shares = orderedShares
                    let lanes = tokenLanes(shares: shares, source: source, destinationX: destinationX)

                    ZStack(alignment: .topLeading) {
                        if showsClassifierLane {
                            classifierLane(lanes[Self.classifierLaneID])
                        }

                        // The pipes themselves: one bore for all of them, lit
                        // by the share each one carries.
                        ForEach(Array(shares.enumerated()), id: \.element.id) { index, share in
                            let destinationY = rowY(index)
                            let tint = ModelFlowPalette.color(for: share.id, in: modelIDs)
                            let isFocused = selectedModelID == nil || selectedModelID == share.id
                            let active = isActive(share.id)

                            if let lane = lanes[share.id] {
                                let glow = pipeGlow(share, isFocused: isFocused, isActive: active)

                                if share.delegatedCount > 0 && share.delegatedCount < share.count {
                                    // The bore stays put; the split is inside
                                    // it, parent above and delegated below.
                                    let splitSide = -1.0 + 2.0 * CGFloat(share.delegatedRatio)

                                    lane.subRibbon(fromSide: splitSide, toSide: 1.0)
                                        .fill(tubeFill(tint, glow))
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)

                                    lane.subRibbon(fromSide: -1.0, toSide: splitSide)
                                        .fill(tubeFill(tint, glow * 0.6))
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)

                                    lane.boundary(side: splitSide)
                                        .stroke(tint.opacity(glow * 2), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                } else if share.delegatedCount > 0 {
                                    // Everything this model served was delegated.
                                    lane.ribbon()
                                        .fill(tubeFill(tint, glow * 0.6))
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                    lane.ribbon()
                                        .stroke(tint.opacity(glow * 2), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                } else {
                                    lane.ribbon()
                                        .fill(tubeFill(tint, glow))
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                }

                                // A rim, so a tube carrying nothing still reads
                                // as a channel waiting for traffic rather than
                                // as a smudge behind the rows.
                                lane.ribbon()
                                    .stroke(tint.opacity(glow * 1.7), lineWidth: 1)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)

                                // The tube's core: a hairline down its middle,
                                // which is what makes the fill read as glass.
                                lane.centerline()
                                    .stroke(tint.opacity(glow * 1.2), lineWidth: 1)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }

                        // Only the active path changes brightness; other paths stay still.
                        pulseView(lanes: lanes, shares: shares)
                            .allowsHitTesting(false)

                        // Over the stream, so the judge leg's flare ends
                        // tucked under the card's edge like the model pipes.
                        if showsClassifierLane {
                            classifierCard(tint: ModelFlowPalette.judge, hasTraffic: (classifierShare?.count ?? 0) > 0)
                                .frame(width: 150, height: 66)
                                .position(x: 93, y: 42)
                        }

                        // The halos, under the cards: the cards are opaque, so
                        // only the light that spills past their edges shows.
                        ModelGlowLayer(
                            glows: modelGlows(shares: shares, rowX: rowX),
                            period: isLive ? FlowMotion.period : FlowMotion.restingPeriod
                        )
                        .frame(
                            width: geometry.size.width + ModelGlowLayer.inset * 2,
                            height: geometry.size.height + ModelGlowLayer.inset * 2
                        )
                        .offset(x: -ModelGlowLayer.inset, y: -ModelGlowLayer.inset)

                        // The model cards, on top of the lanes and streams so
                        // every flare ends tucked under its card's edge.
                        ForEach(Array(shares.enumerated()), id: \.element.id) { index, share in
                            let destinationY = rowY(index)
                            let tint = ModelFlowPalette.color(for: share.id, in: modelIDs)
                            let isFocused = selectedModelID == nil || selectedModelID == share.id
                            let active = isActive(share.id)

                            modelButton(share, tint: tint, isActive: active, isFocused: isFocused)
                                .frame(width: Self.rowWidth, height: modelRowHeight, alignment: .leading)
                                .position(x: rowX + Self.rowWidth / 2, y: destinationY)
                        }

                        sourceNode
                            .frame(width: 150, height: 102)
                            .position(x: 93, y: source.y)
                    }
                }
                .frame(height: chartHeight)
            }

            if let emptyStateMessage {
                HStack(spacing: 7) {
                    Image(systemName: "clock")
                    Text(emptyStateMessage)
                }
                .font(RouterTheme.mono(10))
                .foregroundStyle(RouterTheme.ink3)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(RouterTheme.panel)
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(
                            colors: [RouterTheme.accent.opacity(0.045), .clear],
                            startPoint: .topTrailing, endPoint: .bottomLeading
                        ))
                }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(RouterTheme.line2, lineWidth: 1))
    }

    private var emptyStateMessage: String? {
        guard metrics.isEmpty else { return nil }
        if let session = contextSession {
            return "\(session.shortTitle) has no calls left in the log's tail."
        }
        return isRouting
            ? "Ready for requests. Model activity appears as Codex sends turns."
            : "No requests in the last 15 minutes."
    }

    // MARK: - Geometry

    /// Every tube leaves from the same point on the router's edge, tucked a
    /// hair under the card, and tangents at both ends are horizontal: the
    /// bundle leaves the router square to its edge, fans out, and each tube
    /// meets its model horizontally.
    private func laneCurve(
        source: CGPoint,
        destinationX: CGFloat,
        destinationY: CGFloat
    ) -> TokenStream.Curve {
        let span = destinationX - source.x
        let start = CGPoint(x: source.x - Self.dockTuck, y: source.y)
        return TokenStream.Curve(
            start: start,
            control1: CGPoint(x: source.x + span * 0.5, y: start.y),
            control2: CGPoint(x: destinationX - span * 0.5, y: destinationY),
            end: CGPoint(x: destinationX, y: destinationY)
        )
    }

    /// Half a tube's thickness where it leaves the router. A role that served
    /// nothing keeps a thin tube -- a dark port, not a missing one -- and the
    /// busiest grows to `pipeRadius`. The mouth at the model is the same for
    /// all of them, because it docks along the card's whole edge.
    private static let idleRadius: CGFloat = 2
    private static let pipeRadius: CGFloat = 7

    static func tubeRadius(share: Double, hasTraffic: Bool) -> CGFloat {
        guard hasTraffic else { return idleRadius }
        return idleRadius + (pipeRadius - idleRadius) * CGFloat(TokenStream.prominence(share: share))
    }

    /// Glass rather than paint: densest where the tube leaves the router,
    /// where the bundle overlaps itself, and thinning towards the model that
    /// has its own light.
    private func tubeFill(
        _ tint: Color, _ glow: Double, from start: UnitPoint = .leading, to end: UnitPoint = .trailing
    ) -> LinearGradient {
        LinearGradient(
            colors: [tint.opacity(min(glow * 1.5, 1)), tint.opacity(glow * 0.75)],
            startPoint: start, endPoint: end
        )
    }

    /// The halo behind each used model's card, and behind the classifier's,
    /// which lights up the same way.
    private func modelGlows(shares: [RoutingMetrics.Share], rowX: CGFloat) -> [ModelGlowLayer.Glow] {
        var glows = [ModelGlowLayer.Glow]()
        let judged = metrics.classifierCount
        if showsClassifierLane, judged > 0 {
            let level = ModelGlowLayer.level(
                share: Double(judged) / Double(max(metrics.count + judged, 1)), hasTraffic: true,
                isActive: classifierIsActive, isSelected: false, isFocused: selectedModelID == nil
            )
            glows.append(ModelGlowLayer.Glow(
                id: Self.classifierLaneID,
                rect: CGRect(x: 18, y: 9, width: 150, height: 66),
                cornerRadius: 10,
                tint: ModelFlowPalette.judge,
                level: level,
                pulses: classifierIsActive && isAnimating && selectedModelID == nil
            ))
        }
        return glows + shares.enumerated().compactMap { index, share in
            let level = ModelGlowLayer.level(
                share: share.share, hasTraffic: share.count > 0,
                isActive: isActive(share.id), isSelected: selectedModelID == share.id,
                isFocused: selectedModelID == nil || selectedModelID == share.id
            )
            guard level > 0 else { return nil }
            return ModelGlowLayer.Glow(
                id: share.id,
                rect: CGRect(
                    x: rowX, y: rowY(index) - modelRowHeight / 2,
                    width: Self.rowWidth, height: modelRowHeight
                ),
                cornerRadius: Self.rowCornerRadius,
                tint: ModelFlowPalette.color(for: share.id, in: modelIDs),
                level: level,
                pulses: isActive(share.id) && isAnimating
                    && (selectedModelID == nil || selectedModelID == share.id)
            )
        }
    }

    /// The model cards' corners. The flare meets a card along the straight
    /// part of its edge, between these.
    private static let rowCornerRadius: CGFloat = 8

    /// How far a lane runs on under its card, so the two overlap rather than
    /// leaving a hairline between them.
    private static let dockTuck: CGFloat = 2

    /// Half a pipe's section where it meets its card: the card's whole
    /// straight edge, so the stream docks into the card instead of pointing
    /// at it. The pipe opens out to this slowly, from the router's bore.
    private var flareRadius: CGFloat { modelRowHeight / 2 - Self.rowCornerRadius }

    /// The destination rows' own width: a name, its numbers and the context
    /// gauge, each in a column that stays put from row to row.
    private static let rowWidth: CGFloat = 326

    /// Every lane the map draws, by the model it serves: the served legs, plus
    /// the judge leg under `classifierLaneID` when the algorithm asks one.
    /// Laid out once per geometry pass and shared by the beds and the streams.
    func tokenLanes(
        shares: [RoutingMetrics.Share],
        source: CGPoint,
        destinationX: CGFloat
    ) -> [String: TokenStream.Lane] {
        var lanes = [String: TokenStream.Lane]()
        lanes.reserveCapacity(shares.count + 1)

        // Every row gets a pipe, including one that served nothing: an unused
        // role is a dark port on the router, not a missing one.
        for (index, share) in shares.enumerated() {
            lanes[share.id] = TokenStream.Lane(
                id: share.id,
                curve: laneCurve(source: source, destinationX: destinationX, destinationY: rowY(index)),
                tint: ModelFlowPalette.color(for: share.id, in: modelIDs),
                share: share.count > 0 ? share.share : 0,
                spread: Self.tubeRadius(share: share.share, hasTraffic: share.count > 0),
                endSpread: flareRadius,
                isActive: isActive(share.id)
            )
        }

        // The judge leg carries calls of its own, so it gets its own stream --
        // in its own colour, and never out of the served lanes' budget.
        // Laid out even before the judge has answered anything, so the leg is
        // a dark pipe waiting for its first check rather than a missing one.
        if showsClassifierLane {
            let total = max(metrics.count + metrics.classifierCount, 1)
            lanes[Self.classifierLaneID] = TokenStream.Lane(
                id: Self.classifierLaneID,
                curve: TokenStream.Curve(
                    from: CGPoint(x: 93, y: sourceY - 51 + Self.dockTuck),
                    to: CGPoint(x: 93, y: classifierCardBottom - Self.dockTuck)
                ),
                tint: ModelFlowPalette.judge,
                share: Double(metrics.classifierCount) / Double(total),
                // Every routed turn asks the judge first, so its leg carries
                // real traffic both ways: a full pipe out of the router's top
                // edge, opening into the classifier card's underside.
                spread: Self.tubeRadius(
                    share: Double(metrics.classifierCount) / Double(total), hasTraffic: metrics.classifierCount > 0
                ),
                endSpread: Self.judgeMouth,
                isActive: classifierIsActive
            )
        }
        return lanes
    }

    private static let classifierLaneID = "\u{0}classifier"

    func pulseView(
        lanes: [String: TokenStream.Lane], shares: [RoutingMetrics.Share]
    ) -> FlowPulseView {
        FlowPulseView(lanes: streamingLanes(lanes, shares: shares), activity: activity)
    }

    /// The lanes eligible to pulse: picking a model quiets the rest of
    /// the map, judge leg included, so the one being explored stands alone.
    /// Kept in the shares' own order, so the canvas draws them back to front
    /// the same way every frame.
    private func streamingLanes(
        _ lanes: [String: TokenStream.Lane],
        shares: [RoutingMetrics.Share]
    ) -> [TokenStream.Lane] {
        guard let selectedModelID else {
            return shares.compactMap { lanes[$0.id] }
                + [lanes[Self.classifierLaneID]].compactMap { $0 }
        }
        return [lanes[selectedModelID]].compactMap { $0 }
    }

    // MARK: - Nodes

    /// Half the judge leg's mouth where it opens into the classifier card.
    private static let judgeMouth: CGFloat = 30

    /// The judge leg: a pipe from the router up into the classifier card,
    /// lit by its share of the calls. The shared pulse layer highlights it
    /// while the judge is active.
    @ViewBuilder
    private func classifierLane(_ lane: TokenStream.Lane?) -> some View {
        if let lane {
            let tint = ModelFlowPalette.judge
            let hasTraffic = metrics.classifierCount > 0
            let glow = classifierGlow(hasTraffic: hasTraffic)
            let pipe = lane.ribbon()

            // Drawn exactly like the model tubes -- glass fill, rim and a
            // hairline core -- only running up out of the router instead of
            // across, so the gradient is densest at the router end.
            pipe.fill(tubeFill(tint, glow, from: .bottom, to: .top))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            pipe.stroke(tint.opacity(glow * 1.7), lineWidth: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            lane.centerline()
                .stroke(tint.opacity(glow * 1.2), lineWidth: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// The judge leg's bed, on the same scale as the model pipes' and quieted
    /// with them while one model is being explored.
    private func classifierGlow(hasTraffic: Bool) -> Double {
        let isFocused = selectedModelID == nil
        guard hasTraffic else { return isFocused ? 0.05 : 0.03 }
        let share = Double(metrics.classifierCount) / Double(max(metrics.count + metrics.classifierCount, 1))
        let base = 0.08 + 0.2 * TokenStream.prominence(share: share) + (classifierIsActive ? 0.06 : 0)
        return isFocused ? base : base * 0.35
    }

    private func classifierCard(tint: Color, hasTraffic: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .foregroundStyle(hasTraffic ? tint : RouterTheme.ink3)
                Text("Classifier")
                    .font(RouterTheme.sans(11, .medium))
                    .foregroundStyle(hasTraffic ? RouterTheme.ink : RouterTheme.ink2)
                Spacer(minLength: 0)
                if classifierIsActive, isLive {
                    Circle().fill(tint).frame(width: 5, height: 5)
                }
            }
            Text(classifierLabel)
                .font(RouterTheme.mono(10))
                .foregroundStyle(RouterTheme.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(hasTraffic
                 ? "\(metrics.classifierCount) calls · \(ModelFlowPalette.rate(classifierShare?.requestsPerSecond ?? 0)) req/s"
                 : "no judge calls yet")
                .font(RouterTheme.mono(10))
                .foregroundStyle(RouterTheme.ink3)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .background(RouterTheme.panel2, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(hasTraffic ? tint.opacity(classifierIsActive ? 0.55 : 0.3) : RouterTheme.line2)
        )
        .workingShimmer(
            tint: tint,
            isWorking: classifierIsActive && isAnimating,
            cornerRadius: 10,
            period: isLive ? FlowMotion.period : FlowMotion.restingPeriod
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Classifier \(classifierLabel), \(metrics.classifierCount) judge calls, not counted as served turns")
    }

    private var sourceNode: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(RouterTheme.accent)
                Text("switchyard-desktop")
                    .font(RouterTheme.sans(14, .semibold))
                    .foregroundStyle(RouterTheme.ink)
            }
            Text("\(ModelFlowPalette.rate(metrics.requestsPerSecond)) req/s")
                .font(RouterTheme.mono(11))
                .foregroundStyle(RouterTheme.ink2)
            Text("\(metrics.count) requests")
                .font(RouterTheme.mono(10))
                .foregroundStyle(RouterTheme.ink3)
            if metrics.delegatedCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 8.5))
                    Text("\(metrics.delegatedCount) delegated (\(Int((metrics.delegatedTokenRatio * 100).rounded()))% tokens)")
                }
                .font(RouterTheme.mono(9.5))
                .foregroundStyle(RouterTheme.ink2)
                .help("\(metrics.delegatedCount) delegated requests across \(metrics.uniqueSubagentsCount) subagents (\(metrics.delegatedTokens.formatted()) tokens)")
            }
            if showsContext, let routeContextWindow {
                Text("Route window \(routeContextWindow.formatted(.number.notation(.compactName)))")
                    .font(RouterTheme.mono(9))
                    .foregroundStyle(RouterTheme.ink2)
                    .help("Current route declaration: \(routeContextWindow.formatted()) tokens, from \(isRouting ? "the running Switchyard server" : "the saved Switchyard configuration"). Advertised to clients; it does not enforce a limit or change the upstream model's window.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .background(RouterTheme.panel2, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(RouterTheme.accent.opacity(0.3)))
        .accessibilityElement(children: .combine)
    }

    /// The row's own name: the role the user wrote, falling back to the model
    /// for a route whose targets carry none.
    private func rowTitle(_ share: RoutingMetrics.Share) -> String {
        roles[share.id]?.name ?? share.id
    }

    /// What sits under that name: which model serves the role and at what
    /// effort. Without a role the line carries the rate instead, so the row
    /// never loses its second line.
    private func rowDetail(_ share: RoutingMetrics.Share) -> String {
        guard let role = roles[share.id] else {
            return "\(ModelFlowPalette.rate(share.requestsPerSecond)) req/s"
        }
        guard let effort = role.effort else { return share.id }
        return "\(share.id)  ·  \(effort.rawValue)"
    }

    private func modelButton(
        _ share: RoutingMetrics.Share,
        tint: Color,
        isActive: Bool,
        isFocused: Bool
    ) -> some View {
        let usage = contextUsage[share.id] ?? ModelContextUsage(inputTokens: nil, contextWindow: nil)
        let idle = share.count == 0
        return Button {
            selectedModelID = selectedModelID == share.id ? nil : share.id
        } label: {
            HStack(spacing: 9) {
                if showsEffortLadder {
                    EffortLadder(effort: roles[share.id]?.effort, tint: tint, isDim: idle || !isFocused)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(rowTitle(share))
                            .font(RouterTheme.sans(13, .medium))
                            .foregroundStyle(idle ? RouterTheme.ink2 : RouterTheme.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if isActive {
                            Text(isLive ? "live" : "last")
                                .font(RouterTheme.mono(9, .medium))
                                .tracking(0.6)
                                .foregroundStyle(tint)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(tint.opacity(0.13), in: Capsule())
                                .layoutPriority(1)
                        }
                        if share.delegatedCount > 0 {
                            Text(share.delegatedCount == share.count ? "sub" : "\(share.delegatedCount) sub")
                                .font(RouterTheme.mono(8.5, .medium))
                                .foregroundStyle(tint)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1))
                                .layoutPriority(1)
                                .help("\(share.delegatedCount) delegated subagent requests (\(Int((share.delegatedRatio * 100).rounded()))% of traffic)")
                        }
                    }
                    Text(rowDetail(share))
                        .font(RouterTheme.mono(10.5))
                        .foregroundStyle(RouterTheme.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                shareColumn(share)
                if showsContext {
                    contextGauge(usage, tint: tint, isIdle: idle)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            // Opaque, so the flare that docks into the card ends under it.
            .background {
                RoundedRectangle(cornerRadius: Self.rowCornerRadius)
                    .fill(RouterTheme.panel2)
                    .overlay {
                        if selectedModelID == share.id {
                            RoundedRectangle(cornerRadius: Self.rowCornerRadius).fill(tint.opacity(0.08))
                        }
                    }
            }
            .overlay(
                RoundedRectangle(cornerRadius: Self.rowCornerRadius)
                    .strokeBorder(isActive ? tint.opacity(0.35) : (idle ? RouterTheme.line : tint.opacity(0.18)))
            )
            // The role whose model is working right now shimmers: faster
            // while tokens move, on the slower breath while it thinks.
            .workingShimmer(
                tint: tint,
                isWorking: isActive && isAnimating && isFocused,
                cornerRadius: Self.rowCornerRadius,
                period: isLive ? FlowMotion.period : FlowMotion.restingPeriod
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(rowHelp(share, usage: usage))
        .accessibilityLabel(rowDescription(share, isActive: isActive, usage: usage))
        .accessibilityAddTraits(selectedModelID == share.id ? .isSelected : [])
    }

    /// The numbers, kept in a column of their own so the names on the left
    /// stay a column of names.
    ///
    /// The share carries the turns it was taken from rather than a bare count:
    /// two unlabelled percentages on one row -- this one and the context
    /// gauge's -- left the reader to guess which was which.
    private func shareColumn(_ share: RoutingMetrics.Share) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            // Named, because the context gauge next to it shows a percentage
            // too: two bare numbers on one row left the reader to work out
            // which was traffic and which was a window.
            Text("TRAFFIC")
                .font(RouterTheme.mono(8))
                .tracking(0.7)
                .foregroundStyle(RouterTheme.ink3)
            Text(share.share.formatted(.percent.precision(.fractionLength(0))))
                .font(RouterTheme.mono(12, .medium))
                .foregroundStyle(share.count == 0 ? RouterTheme.ink3 : RouterTheme.ink)
            Text("\(share.count.formatted()) of \(metrics.count.formatted())")
                .font(RouterTheme.mono(9.5))
                .foregroundStyle(RouterTheme.ink3)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityHidden(true)
    }

    /// Everything the row leaves out, including the rate its second line gave
    /// up to the role.
    private func rowHelp(_ share: RoutingMetrics.Share, usage: ModelContextUsage) -> String {
        var lines = [rowTitle(share)]
        if let role = roles[share.id] {
            let effort = role.effort.map { "effort \($0.rawValue)" } ?? "the model's own effort"
            lines[0] = "\(role.name) · \(share.id) · \(effort)"
        }
        lines.append("\(share.count) requests · \(ModelFlowPalette.rate(share.requestsPerSecond)) req/s")
        if share.delegatedCount > 0 {
            lines.append("\(share.parentCount) parent, \(share.delegatedCount) subagent")
        }
        if let detail = contextDetail(usage, isIdle: share.count == 0) { lines.append(detail) }
        lines.append("Show latency for this model.")
        return lines.joined(separator: "\n")
    }

    private func rowDescription(
        _ share: RoutingMetrics.Share,
        isActive: Bool,
        usage: ModelContextUsage
    ) -> String {
        var parts: [String] = []
        if let role = roles[share.id] {
            parts.append("\(role.name) role on \(share.id)")
            if let effort = role.effort { parts.append("effort \(effort.displayName.lowercased())") }
        } else {
            parts.append(share.id)
        }
        parts.append("\(share.count) requests")
        if share.delegatedCount > 0 { parts.append("\(share.delegatedCount) delegated") }
        parts.append("\(share.share.formatted(.percent)) of traffic")
        if isActive { parts.append("served the most recent request") }
        if let detail = contextDetail(usage, isIdle: share.count == 0) { parts.append(detail) }
        return parts.joined(separator: ", ")
    }

    /// The context sentence for one row, naming the conversation it reads.
    private func contextDetail(_ usage: ModelContextUsage, isIdle: Bool = false) -> String? {
        guard let session = contextSession else { return nil }
        // Spelled out for the row the pair confuses most: no traffic in the
        // window, and a window reading that came from before it.
        let stale = isIdle
            ? " This role served nothing in the window above, so the reading is from an earlier turn."
            : ""
        return "\(usage.explanation)\(stale) Conversation: \(session.scopeName)."
    }

    /// The context gauge names what it fills: without the caption its
    /// percentage sat beside the share's own with nothing to tell them apart.
    /// - Parameter isIdle: The row served nothing inside the window the shares
    ///   are taken from. Its snapshot is from an earlier turn of the same
    ///   conversation, which is exactly the pair that read as a contradiction:
    ///   a role at 0% of the traffic beside a window filled to 81%.
    private func contextGauge(_ usage: ModelContextUsage, tint: Color, isIdle: Bool) -> some View {
        let fraction = usage.fraction ?? 0
        let live = fraction >= 0.95 ? RouterTheme.crit : (fraction >= 0.8 ? RouterTheme.warn : tint)
        // A stale snapshot does not get to raise an alarm about a window that
        // nothing in this window filled.
        let color = isIdle ? RouterTheme.ink3 : live
        return VStack(spacing: 2) {
            // The caption above the arc, matching the one over the share, so
            // the row's two percentages each say what they measure -- and when
            // the snapshot predates the window, that it does.
            Text(isIdle ? "LAST CONTEXT" : "CONTEXT")
                .font(RouterTheme.mono(8))
                .tracking(0.7)
                .foregroundStyle(RouterTheme.ink3)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            ZStack {
                Circle().stroke(RouterTheme.line2, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: usage.fillFraction)
                    .stroke(color.opacity(isIdle ? 0.5 : 1), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(usage.percentage)
                    .font(RouterTheme.mono(9, .medium))
                    .foregroundStyle(usage.fraction == nil ? RouterTheme.ink3 : color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(4)
            }
            .frame(width: 34, height: 34)
            Text(usage.tokenLabel)
                .font(RouterTheme.mono(8.5))
                .foregroundStyle(RouterTheme.ink3)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: 74)
        .accessibilityHidden(true)
    }

    private func rowY(_ index: Int) -> CGFloat {
        guard metrics.shares.count > 1 else { return chartHeight / 2 }
        return rowInset + CGFloat(index) * (chartHeight - rowInset * 2) / CGFloat(metrics.shares.count - 1)
    }

    /// How brightly a pipe's bed is drawn: its share of the traffic, lifted
    /// for the leg that carried the newest call and dimmed while another row is
    /// being explored. Together with its thickness at the router, this is what
    /// a tube says about usage.
    private func pipeGlow(
        _ share: RoutingMetrics.Share,
        isFocused: Bool,
        isActive: Bool
    ) -> Double {
        guard share.count > 0 else { return isFocused ? 0.05 : 0.03 }
        let base = 0.07 + 0.2 * TokenStream.prominence(share: share.share) + (isActive ? 0.05 : 0)
        return isFocused ? base : base * 0.35
    }
}

/// How hard a role asks its model to think, as a six-step column filled from
/// the bottom: the same ladder the rows are ordered by, so a row's place and
/// its mark say the same thing.
///
/// A role naming no effort leaves the column empty rather than absent, which
/// keeps every row's text on the same left edge.
private struct EffortLadder: View {
    package let effort: RoutingRole.Effort?
    package let tint: Color
    package let isDim: Bool

    private var filled: Int {
        guard let effort, let level = RoutingRole.Effort.allCases.firstIndex(of: effort) else {
            return 0
        }
        return level + 1
    }

    package var body: some View {
        VStack(spacing: 1.5) {
            ForEach(0..<FlowRole.levels, id: \.self) { step in
                RoundedRectangle(cornerRadius: 1)
                    .fill(FlowRole.levels - step <= filled ? tint.opacity(isDim ? 0.35 : 0.85) : RouterTheme.line)
                    .frame(width: 7, height: 3)
            }
        }
        .accessibilityHidden(true)
    }
}

package enum ModelFlowPalette {
    private static let colors: [Color] = [
        RouterTheme.accent, RouterTheme.p95, Color(hex: 0xD4B17D),
        Color(hex: 0xA99BD4), Color(hex: 0x6EB9B6), Color(hex: 0xCD8F99),
    ]

    /// The judge leg never competes with a model for a hue: it is routing
    /// overhead, not a destination for a user's turn.
    package static let judge = Color(hex: 0x8AA0B4)

    package static func color(for model: String, in modelIDs: [String]) -> Color {
        colors[(modelIDs.firstIndex(of: model) ?? 0) % colors.count]
    }

    package static func rate(_ value: Double) -> String {
        value == 0 ? "0" : String(format: value < 0.1 ? "%.4f" : "%.2f", value)
    }
}
