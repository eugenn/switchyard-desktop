import SwiftUI

/// The routing map as a signal box: the classifier (or the router itself) on
/// the left, one rail per route fanning out from it, and each route drawn as a
/// lane whose track carries a tick for every turn it served in the window.
///
/// Where the old flow map spread traffic share, the routed-turns chart and the
/// context gauges over three separate figures, a lane holds all three: its
/// share as a number, its history as ticks along a shared time axis, and how
/// full the conversation's context is on that model.
package struct SignalBoxView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.routingWindowVisible) private var windowVisible

    /// One served turn on a lane's track: where it sits in the window (0...1)
    /// and how heavy it was relative to the heaviest turn on the map (0...1).
    package struct Tick: Equatable, Sendable {
        package let position: Double
        package let weight: Double
    }

    package let metrics: RoutingMetrics
    package let modelIDs: [String]
    package let isRouting: Bool
    package var asOf: Date?
    package var usesClassifier = false
    package var classifierModelID: String?
    package var roles: [String: FlowRole] = [:]
    package var ticks: [String: [Tick]] = [:]
    package var contextUsage: [String: ModelContextUsage] = [:]
    package var contextSession: RoutingSession?
    package var sessions: [RoutingSession] = []
    package var activeSessionIDs: Set<String> = []
    @Binding var selectedModelID: String?
    package var selectedSessionID: Binding<String?> = .constant(nil)

    // MARK: Layout

    private static let sourceWidth: CGFloat = 164
    private static let railWidth: CGFloat = 76
    private static let labelWidth: CGFloat = 214
    private static let contextWidth: CGFloat = 108
    private static let laneHeight: CGFloat = 58
    private static let laneSpacing: CGFloat = 8
    private static let nodeHeight: CGFloat = 74
    private static let minimumBodyHeight: CGFloat = 214

    /// Same windows the old map used: a call within 8 s is live, and the
    /// served lane keeps breathing for 10 minutes while the model thinks.
    private static let liveWindow: TimeInterval = 8
    private static let thinkingWindow: TimeInterval = 600

    private var lanes: [RoutingMetrics.Share] { FlowRole.ordered(metrics.shares, roles: roles) }
    private var showsClassifier: Bool { usesClassifier || !metrics.classifierShares.isEmpty }
    private var showsContext: Bool { contextSession != nil }

    private var lanesHeight: CGFloat {
        let count = CGFloat(lanes.count)
        return count * Self.laneHeight + max(count - 1, 0) * Self.laneSpacing
    }

    private var bodyHeight: CGFloat { max(Self.minimumBodyHeight, lanesHeight + 24) }

    private func laneCenter(_ index: Int) -> CGFloat {
        (bodyHeight - lanesHeight) / 2 + CGFloat(index) * (Self.laneHeight + Self.laneSpacing) + Self.laneHeight / 2
    }

    // MARK: Activity

    private var latest: RoutingMetrics.Latest? { metrics.latest }

    private var sinceLatest: TimeInterval? {
        guard let at = latest?.at else { return nil }
        return (asOf ?? metrics.windowEnd).timeIntervalSince(at)
    }

    private var isLive: Bool {
        guard isRouting, latest != nil else { return false }
        return (sinceLatest ?? 0) <= Self.liveWindow
    }

    private var isThinking: Bool {
        guard isRouting, !isLive, let since = sinceLatest else { return false }
        return since <= Self.thinkingWindow
    }

    private var latestModelID: String? {
        guard let latest, !latest.isClassifier else { return nil }
        return latest.modelID
    }

    private func tint(_ id: String) -> Color { ModelFlowPalette.color(for: id, in: modelIDs) }

    // MARK: Body

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            RouterDivider()

            if metrics.subagentIdentityUnsupported {
                identityWarning
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            if lanes.isEmpty {
                StatsEmptyState(
                    message: contextSession == nil
                        ? "Assign models in Routing config to see where requests go."
                        : "This session routed no turns the log could attribute to a model."
                )
                .frame(maxWidth: .infinity)
                .frame(height: 160)
            } else {
                map
                axis
            }
        }
        .background(RouterTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(RouterTheme.line, lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Where requests go")
                .font(RouterTheme.sans(14, .semibold))
                .foregroundStyle(RouterTheme.ink)
            Text(windowLabel)
                .font(RouterTheme.sans(11.5))
                .foregroundStyle(RouterTheme.ink3)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let latest, isLive || isThinking {
                let name = latest.isClassifier ? "classifier" : (roles[latest.modelID]?.name ?? latest.modelID)
                LiveBadge(
                    tint: isLive ? (latest.isClassifier ? ModelFlowPalette.judge : tint(latest.modelID)) : RouterTheme.ink3,
                    text: isLive ? name : "waiting",
                    font: RouterTheme.sans(11),
                    blinks: isLive,
                    accessibilityText: isLive
                        ? nil
                        : "Routing is on and no tokens have moved since \(name) answered. The model may still be thinking."
                )
            }
            if !sessions.isEmpty || isRouting {
                SessionPicker(
                    sessions: sessions, selection: selectedSessionID,
                    activeSessionIDs: activeSessionIDs, allowsAll: false
                )
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private var windowLabel: String {
        guard let session = contextSession else { return "Last 15 minutes" }
        guard let span = session.span, span.duration >= 1 else { return "One session" }
        return "This session · \(Self.durationText(span.duration))"
    }

    private var identityWarning: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(RouterTheme.warn)
                .font(.system(size: 11))
            Text("Harness does not send subagent identity; delegated requests route through parent.")
                .font(RouterTheme.sans(11.5))
                .foregroundStyle(RouterTheme.ink2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RouterTheme.warn.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Map

    private var map: some View {
        HStack(spacing: 0) {
            source
                .frame(width: Self.sourceWidth, height: bodyHeight)
            rails
                .frame(width: Self.railWidth, height: bodyHeight)
            VStack(spacing: Self.laneSpacing) {
                ForEach(lanes) { share in
                    lane(share)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: bodyHeight)
            .padding(.trailing, 14)
        }
        .padding(.leading, 16)
    }

    /// The node every rail leaves from, centred on the lanes it feeds, with
    /// the client that sends it turns hung above it.
    private var source: some View {
        let center = bodyHeight / 2
        return ZStack(alignment: .topLeading) {
            if showsClassifier {
                HStack(spacing: 7) {
                    Text("codex")
                        .font(RouterTheme.mono(11))
                        .foregroundStyle(RouterTheme.ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(RouterTheme.line2, lineWidth: 1))
                    Text("local client")
                        .font(RouterTheme.sans(11.5))
                        .foregroundStyle(RouterTheme.ink3)
                }
                .offset(y: center - Self.nodeHeight / 2 - 44)

                Rectangle()
                    .fill(RouterTheme.accent.opacity(0.75))
                    .frame(width: 1.5, height: 18)
                    .offset(x: 21, y: center - Self.nodeHeight / 2 - 19)
            }
            sourceNode
                .frame(width: Self.sourceWidth - 6, height: Self.nodeHeight)
                .offset(y: center - Self.nodeHeight / 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sourceNode: some View {
        let judging = latest?.isClassifier == true && isLive
        let classifier = metrics.classifierShares.first
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: showsClassifier ? "sparkle" : "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RouterTheme.accent)
                Text(showsClassifier ? "Classifier" : "Switchyard")
                    .font(RouterTheme.sans(13, .semibold))
                    .foregroundStyle(RouterTheme.ink)
            }
            if showsClassifier {
                Text(classifier?.id ?? classifierModelID ?? "not assigned")
                    .font(RouterTheme.mono(11))
                    .foregroundStyle(RouterTheme.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(classifierCadence(metrics.classifierCount))
                    .font(RouterTheme.sans(11))
                    .foregroundStyle(RouterTheme.ink3)
                    .lineLimit(1)
            } else {
                Text("\(metrics.count.formatted()) turns routed")
                    .font(RouterTheme.sans(11))
                    .foregroundStyle(RouterTheme.ink3)
            }
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RouterTheme.panel2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(judging ? ModelFlowPalette.judge.opacity(0.6) : RouterTheme.line2, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    private func classifierCadence(_ calls: Int) -> String {
        let duration = max(metrics.windowEnd.timeIntervalSince(metrics.windowStart), 1)
        guard calls > 1 else { return "\(calls) call" }
        let every = Int((duration / Double(calls)).rounded())
        return every > 0 ? "\(calls.formatted()) calls · 1 per \(Self.durationText(Double(every)))" : "\(calls.formatted()) calls"
    }

    /// One rail per lane, as thick as the share it carries. The rail that
    /// served the newest turn is lit and, while tokens move, carries a dot.
    private var rails: some View {
        let animating = isLive && !reduceMotion && windowVisible
        return TimelineView(.animation(minimumInterval: 1 / 30, paused: !animating)) { context in
            Canvas { canvas, size in
                let origin = CGPoint(x: 0, y: size.height / 2)
                for (index, share) in lanes.enumerated() {
                    let end = CGPoint(x: size.width, y: laneCenter(index))
                    let path = Self.rail(from: origin, to: end)
                    let isLatest = share.id == latestModelID
                    let dimmed = selectedModelID != nil && selectedModelID != share.id
                    let width = share.count == 0 ? 1 : max(1.5, sqrt(share.share) * 9)
                    let opacity = dimmed ? 0.14 : (isLatest ? 0.9 : (share.count == 0 ? 0.2 : 0.4))
                    canvas.stroke(
                        path, with: .color(tint(share.id).opacity(opacity)),
                        style: StrokeStyle(lineWidth: width, lineCap: .round)
                    )
                    if isLatest, animating {
                        let phase = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 1.6) / 1.6
                        let point = Self.point(on: origin, end, at: Self.ease(phase))
                        canvas.fill(
                            Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)),
                            with: .color(Color(hex: 0xE9FFF2))
                        )
                    }
                }
                canvas.fill(
                    Path(ellipseIn: CGRect(x: -3.5, y: origin.y - 3.5, width: 7, height: 7)),
                    with: .color(RouterTheme.accent)
                )
            }
        }
        .accessibilityHidden(true)
    }

    private static func rail(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + (end.x - start.x) * 0.55, y: start.y),
            control2: CGPoint(x: start.x + (end.x - start.x) * 0.45, y: end.y)
        )
        return path
    }

    private static func point(on start: CGPoint, _ end: CGPoint, at t: Double) -> CGPoint {
        let c1 = CGPoint(x: start.x + (end.x - start.x) * 0.55, y: start.y)
        let c2 = CGPoint(x: start.x + (end.x - start.x) * 0.45, y: end.y)
        let u = 1 - t
        let x = u * u * u * start.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * end.x
        let y = u * u * u * start.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * end.y
        return CGPoint(x: x, y: y)
    }

    private static func ease(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    // MARK: Lanes

    private func lane(_ share: RoutingMetrics.Share) -> some View {
        let color = tint(share.id)
        let isLatest = share.id == latestModelID
        let isSelected = selectedModelID == share.id
        let dimmed = selectedModelID != nil && !isSelected
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button {
            selectedModelID = isSelected ? nil : share.id
        } label: {
            HStack(spacing: 0) {
                laneLabel(share, tint: color, isLatest: isLatest)
                    .frame(width: Self.labelWidth, alignment: .leading)
                TickTrack(
                    ticks: ticks[share.id] ?? [],
                    tint: color,
                    marksNewest: isLatest,
                    pulses: isLatest && (isLive || isThinking) && !reduceMotion && windowVisible
                )
                .padding(.leading, 4)
                .padding(.trailing, 18)
                if showsContext {
                    contextMeter(contextUsage[share.id], tint: color, isIdle: share.count == 0)
                        .frame(width: Self.contextWidth)
                        .padding(.trailing, 12)
                }
            }
            .frame(height: Self.laneHeight)
            .background {
                shape.fill(Color.white.opacity(0.018))
                if isLatest {
                    shape.fill(
                        LinearGradient(
                            colors: [color.opacity(0.10), color.opacity(0.03), color.opacity(0.05)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                }
                if isSelected { shape.fill(color.opacity(0.07)) }
            }
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(bottomTrailingRadius: 2, topTrailingRadius: 2)
                    .fill(color.opacity(share.count == 0 ? 0.35 : 1))
                    .frame(width: 3)
                    .padding(.vertical, 12)
            }
            .overlay(
                shape.strokeBorder(
                    isSelected ? color.opacity(0.5) : (isLatest ? color.opacity(0.28) : .clear),
                    lineWidth: 1
                )
            )
            .opacity(dimmed ? 0.5 : 1)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Show every model" : "Show only \(share.id) in latency")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(share))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func laneLabel(_ share: RoutingMetrics.Share, tint: Color, isLatest: Bool) -> some View {
        let idle = share.count == 0
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .trailing, spacing: 1) {
                (Text(share.share.formatted(.number.scale(100).precision(.fractionLength(0))))
                    .font(RouterTheme.sans(21, .semibold))
                    + Text("%").font(RouterTheme.sans(12, .medium)).foregroundColor(RouterTheme.ink2))
                    .foregroundStyle(idle ? RouterTheme.ink3 : RouterTheme.ink)
                Text(share.count == 1 ? "1 turn" : "\(share.count.formatted()) turns")
                    .font(RouterTheme.sans(10.5))
                    .foregroundStyle(RouterTheme.ink3)
            }
            .lineLimit(1)
            .frame(width: 58, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(roles[share.id]?.name ?? share.id)
                        .font(RouterTheme.sans(13, .semibold))
                        .foregroundStyle(idle ? RouterTheme.ink2 : RouterTheme.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isLatest {
                        Text(isLive ? "live" : "latest")
                            .font(RouterTheme.sans(10.5, .medium))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                            .layoutPriority(1)
                    }
                    if share.delegatedCount > 0 {
                        Text(share.delegatedCount == share.count ? "sub" : "\(share.delegatedCount) sub")
                            .font(RouterTheme.sans(10, .medium))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(0.45), lineWidth: 1))
                            .layoutPriority(1)
                            .help("\(share.delegatedCount) delegated subagent requests")
                    }
                }
                laneDetail(share)
            }
        }
        .padding(.leading, 8)
    }

    private func laneDetail(_ share: RoutingMetrics.Share) -> some View {
        let effort = roles[share.id]?.effort?.rawValue
        let model = roles[share.id] == nil ? "\(ModelFlowPalette.rate(share.requestsPerSecond)) req/s" : share.id
        return (Text(model).foregroundColor(RouterTheme.ink2)
            + Text(effort.map { " · \($0)" } ?? "").foregroundColor(RouterTheme.ink3))
            .font(RouterTheme.mono(11))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func contextMeter(_ usage: ModelContextUsage?, tint: Color, isIdle: Bool) -> some View {
        let usage = usage ?? ModelContextUsage(inputTokens: nil, contextWindow: nil)
        let fraction = usage.fraction ?? 0
        let alarm = fraction >= 0.95 ? RouterTheme.crit : (fraction >= 0.8 ? RouterTheme.warn : tint)
        let color = isIdle ? RouterTheme.ink3 : alarm
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(isIdle ? "last context" : "context")
                    .font(RouterTheme.sans(11))
                    .foregroundStyle(RouterTheme.ink3)
                Spacer(minLength: 4)
                Text(usage.percentage)
                    .font(RouterTheme.sans(12, .semibold))
                    .foregroundStyle(fraction >= 0.8 && !isIdle ? alarm : RouterTheme.ink)
            }
            Capsule()
                .fill(RouterTheme.fill)
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(color.opacity(isIdle ? 0.5 : 0.9))
                            .frame(width: proxy.size.width * usage.fillFraction)
                    }
                }
            Text(usage.tokenLabel)
                .font(RouterTheme.mono(10.5))
                .foregroundStyle(RouterTheme.ink3)
                .lineLimit(1)
        }
        .help(usage.fraction == nil ? "No context reading for this model in the session yet." : "Input tokens of the session's latest turn on this model, against its context window.")
    }

    private func accessibilityLabel(_ share: RoutingMetrics.Share) -> String {
        let name = roles[share.id]?.name ?? share.id
        let percent = share.share.formatted(.percent.precision(.fractionLength(0)))
        return "\(name), \(share.id), \(percent) of traffic, \(share.count) turns"
    }

    // MARK: Axis

    private var axis: some View {
        HStack(spacing: 0) {
            Text(metrics.windowStart.formatted(date: .omitted, time: .shortened))
            Spacer(minLength: 8)
            Text("each tick is one turn · taller means more tokens")
                .foregroundStyle(RouterTheme.ink3.opacity(0.85))
            Spacer(minLength: 8)
            Text(isRouting ? "now" : metrics.windowEnd.formatted(date: .omitted, time: .shortened))
        }
        .font(RouterTheme.sans(10.5))
        .foregroundStyle(RouterTheme.ink3)
        .padding(.leading, 16 + Self.sourceWidth + Self.railWidth + Self.labelWidth + 4)
        .padding(.trailing, 14 + 18 + (showsContext ? Self.contextWidth + 12 : 0))
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    // MARK: Helpers

    package static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        if total < 3_600 { return "\(total / 60) min" }
        return "\(total / 3_600) h \((total % 3_600) / 60) min"
    }

    /// Served turns placed on the window's time axis, per model. Weights are
    /// relative to the heaviest turn anywhere on the map, so a lane's tall
    /// ticks really are the expensive turns, not just its own largest.
    package static func ticks(
        records: [RoutingLogRecord],
        sessionID: String?,
        start: Date,
        end: Date
    ) -> [String: [Tick]] {
        let span = max(end.timeIntervalSince(start), 1)
        var placed: [String: [(Double, Int)]] = [:]
        var heaviest = 1
        for record in records where !record.isClassifier {
            if let sessionID, record.sessionID != sessionID { continue }
            guard let timestamp = record.timestamp else { continue }
            let position = timestamp.timeIntervalSince(start) / span
            guard position >= -0.001, position <= 1.001 else { continue }
            let tokens = record.tokens.total
            heaviest = max(heaviest, tokens)
            placed[record.modelIdentity, default: []].append((min(max(position, 0), 1), tokens))
        }
        return placed.mapValues { turns in
            turns
                .sorted { $0.0 < $1.0 }
                .map { Tick(position: $0.0, weight: sqrt(Double($0.1) / Double(heaviest))) }
        }
    }
}

/// A lane's track: a baseline with one tick per served turn. The newest tick
/// on the lane that served the latest turn carries a ring, which pulses while
/// tokens are moving or the model is still thinking.
private struct TickTrack: View {
    let ticks: [SignalBoxView.Tick]
    let tint: Color
    let marksNewest: Bool
    let pulses: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !pulses)) { context in
            Canvas { canvas, size in
                let baseline = size.height - 9
                canvas.fill(
                    Path(CGRect(x: 0, y: baseline, width: size.width, height: 1)),
                    with: .color(RouterTheme.line2)
                )
                for (index, tick) in ticks.enumerated() {
                    let isNewest = marksNewest && index == ticks.count - 1
                    let height = isNewest ? 26 : 6 + 22 * tick.weight
                    let x = 6 + tick.position * (size.width - 15)
                    canvas.fill(
                        Path(roundedRect: CGRect(x: x, y: baseline - height, width: 3, height: height), cornerRadius: 1.2),
                        with: .color(tint.opacity(isNewest ? 1 : 0.72))
                    )
                }
                guard marksNewest, let newest = ticks.last else { return }
                let center = CGPoint(x: 6 + newest.position * (size.width - 15) + 1.5, y: baseline + 1)
                if pulses {
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
                    let radius = 6 + 9 * phase
                    canvas.fill(
                        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                        with: .color(tint.opacity(0.35 * (1 - phase)))
                    )
                }
                canvas.stroke(
                    Path(ellipseIn: CGRect(x: center.x - 5.5, y: center.y - 5.5, width: 11, height: 11)),
                    with: .color(tint), lineWidth: 1.5
                )
            }
        }
        .frame(height: 42)
        .accessibilityHidden(true)
    }
}
