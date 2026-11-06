import SwiftUI

/// Where requests went: a one-line summary of the conversation, the signal
/// box that shows each route's share, history and context, then latency and
/// the newest turns. Below the fold sit the per-target table, the proxy's own
/// lifetime counters and subagent traffic. Everything is computed from the
/// durable routing log plus the proxy's counters.
package struct StatisticsPane: View {
    @Bindable var monitor: RoutingMonitor

    package var body: some View {
        ScrollView {
            let metrics = monitor.activityMetrics
            let session = monitor.flowSession

            VStack(alignment: .leading, spacing: 12) {
                summary(metrics)

                SignalBoxView(
                    metrics: metrics, modelIDs: monitor.modelIDs, isRouting: monitor.isRouting,
                    asOf: monitor.lastRefresh,
                    usesClassifier: monitor.usesClassifier,
                    classifierModelID: monitor.classifierModelID,
                    roles: monitor.flowRoles,
                    ticks: SignalBoxView.ticks(
                        records: monitor.records, sessionID: session?.id,
                        start: metrics.windowStart, end: metrics.windowEnd
                    ),
                    contextUsage: monitor.sessionContextUsage,
                    contextSession: monitor.contextSession,
                    sessions: monitor.sessions,
                    activeSessionIDs: monitor.activeSessionIDs,
                    selectedModelID: $monitor.selectedModelID,
                    selectedSessionID: $monitor.selectedSessionID
                )

                HStack(alignment: .top, spacing: 12) {
                    latencyCard
                        .frame(maxWidth: .infinity)
                    latestTurnsCard(session: session)
                        .frame(maxWidth: .infinity)
                }
                .frame(height: 160)

                modelsAndProxyPanel(metrics)
                subagentsPanel(metrics)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 18)
        }
    }

    // MARK: - Summary

    /// The conversation in one line: five numbers, each with a plain label,
    /// and the scope they are measured over at the end of the line.
    private func summary(_ metrics: RoutingMetrics) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            stat(metrics.count.formatted(), label: Text(metrics.count == 1 ? "request routed" : "requests routed"))
                .help(servedHelp(metrics))
            divider
            errorStat
            divider
            stat(
                metrics.tokens.formatted(.number.notation(.compactName)),
                label: Text(tokensLabel(metrics))
            )
            divider
            stat(cacheEfficiency(metrics), unit: metrics.tokens > 0 ? "%" : nil, label: Text("served from cache"))
                .help(cacheHelp(metrics))
            divider
            costStat(monitor.sessionCost)
            Spacer(minLength: 12)
            scope
        }
        .frame(height: 50)
    }

    private func stat(_ value: String, unit: String? = nil, label: Text, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            (Text(value).font(RouterTheme.sans(23, .semibold))
                + Text(unit ?? "").font(RouterTheme.sans(13, .medium)).foregroundColor(RouterTheme.ink2))
                .foregroundStyle(tint ?? RouterTheme.ink)
                .monospacedDigit()
            label
                .font(RouterTheme.sans(11.5))
                .foregroundStyle(RouterTheme.ink3)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
    }

    private var errorStat: some View {
        let errors = monitor.stats?.totalErrors
        // A failing judge never shows up as an error: the route keeps serving
        // its default target, so name it where the errors are read.
        let warning = monitor.classifierFailure ?? fallbackHighlight
        let label: Text
        if let warning {
            label = Text(warning).foregroundColor(RouterTheme.warn)
        } else if let errors {
            label = Text("● ").foregroundColor(errors > 0 ? RouterTheme.crit : RouterTheme.accent)
                + Text(errors == 1 ? "model error" : "model errors")
        } else {
            label = Text("model errors")
        }
        return stat(
            errors.map(String.init) ?? "—", label: label,
            tint: (errors ?? 0) > 0 ? RouterTheme.crit : nil
        )
        .help("Errors the proxy returned since switchyard-server started.")
    }

    private var scope: some View {
        let session = monitor.flowSession
        let started = session?.startedAt
        return VStack(alignment: .trailing, spacing: 2) {
            Text(session == nil ? "Last 15 minutes" : "This session")
                .font(RouterTheme.sans(11.5, .medium))
                .foregroundStyle(RouterTheme.ink2)
            Group {
                switch (started, monitor.lastRefresh) {
                case let (started?, refresh?):
                    Text("since \(started.formatted(date: .omitted, time: .shortened)) · updated \(refresh.formatted(date: .omitted, time: .standard))")
                case let (nil, refresh?):
                    Text("updated \(refresh.formatted(date: .omitted, time: .standard))")
                case let (started?, nil):
                    Text("since \(started.formatted(date: .omitted, time: .shortened))")
                case (nil, nil):
                    Text("waiting for the first read")
                }
            }
            .font(RouterTheme.sans(11.5))
            .foregroundStyle(RouterTheme.ink3)
            .monospacedDigit()
        }
        .lineLimit(1)
        .padding(.bottom, 1)
    }

    /// When Switchyard fell back because the primary model failed, the error
    /// stat names which fallback took over so the operator sees the failover.
    private var fallbackHighlight: String? {
        guard let stats = monitor.stats else { return nil }
        let active = stats.fallbacks.filter { $0.value > 0 }
        guard let first = active.keys.sorted().first else { return nil }
        return "fallback: \(first)"
    }

    private func servedHelp(_ metrics: RoutingMetrics) -> String {
        let scope = monitor.flowSession == nil ? "the last 15 minutes" : "this session"
        guard let seconds = metrics.secondsPerRequest else { return "Turns routed in \(scope)." }
        return "Turns routed in \(scope), one every \(String(format: "%.1f", seconds)) s."
    }

    private func tokensLabel(_ metrics: RoutingMetrics) -> String {
        guard metrics.count > 0 else { return "tokens" }
        let average = metrics.tokens / metrics.count
        return "tokens · \(average.formatted(.number.notation(.compactName))) per turn"
    }

    private func cacheEfficiency(_ metrics: RoutingMetrics) -> String {
        // `tokens` is the whole prompt Switchyard sent — cached tokens already
        // counted once inside it, not on top of it — so this is the fraction
        // of the prompt that was a cache hit, not a fraction over-counting it.
        guard metrics.tokens > 0 else { return "—" }
        let fraction = Double(metrics.cachedTokens) / Double(metrics.tokens)
        return percent(fraction)
    }

    private func cacheHelp(_ metrics: RoutingMetrics) -> String {
        guard metrics.cachedTokens > 0 else { return "No cache hits in this window." }
        return "\(metrics.cachedTokens.formatted()) of \(metrics.tokens.formatted()) prompt tokens were cache hits."
    }

    /// Approximate spend for the map's conversation at API list prices.
    /// Tokens on a model LiteLLM has no price for are named, not guessed.
    private func costStat(_ cost: TokenCostEstimate) -> some View {
        let hasPrice = cost.pricedCalls > 0
        let unpriced = cost.unpricedModels.first.map { first in
            cost.unpricedModels.count == 1 ? first : "\(first) +\(cost.unpricedModels.count - 1)"
        }
        let label: Text
        if cost.isEmpty {
            label = Text("no calls to price")
        } else if let unpriced {
            label = Text(hasPrice ? "est. · excl. " : "no list price for ")
                + Text(unpriced).foregroundColor(RouterTheme.warn)
        } else {
            label = Text("est. at API list price")
        }
        return stat(hasPrice ? dollars(cost.dollars) : "—", label: label)
            .help(costHelp(cost, session: monitor.flowSession))
    }
    private func costHelp(_ cost: TokenCostEstimate, session: RoutingSession?) -> String {
        let scope = session.map { "\($0.title), judge calls included" } ?? "The last 15 minutes of traffic"
        var lines = [
            "\(scope), priced the way LiteLLM prices a call, from \(priceSource). "
                + "A ChatGPT plan is not billed per token, so this is the equivalent API spend."
        ]
        if cost.pricedCalls > 0, cost.uncachedDollars > cost.dollars {
            lines.append("Cache hits saved about \(dollars(cost.uncachedDollars - cost.dollars)).")
        }
        if !cost.unpricedModels.isEmpty {
            lines.append(
                "Not included: \(cost.unpricedCalls) calls, "
                    + "\(cost.unpricedTokens.formatted(.number.notation(.compactName))) tokens on "
                    + "\(cost.unpricedModels.joined(separator: ", ")), which LiteLLM has no price for."
            )
        }
        lines.append(recalculationNote)
        return lines.joined(separator: "\n")
    }

    private var recalculationNote: String {
        let minutes = max(Int(monitor.recalculationSignal.interval.components.seconds / 60), 1)
        let cadence = "Recalculated with the statistics every \(minutes) min while routing"
        guard let last = monitor.lastCostRecalculation else { return cadence + "." }
        return cadence + ", last at \(last.formatted(date: .omitted, time: .shortened))."
    }

    private var priceSource: String {
        switch monitor.prices.source {
        case .downloaded(let date):
            "LiteLLM's price map as of \(date.formatted(date: .abbreviated, time: .shortened))"
        case .bundled: "the price map bundled with LiteLLM"
        case .none: "no price map"
        }
    }

    private func dollars(_ value: Double) -> String {
        if value > 0, value < 0.01 { return "<$0.01" }
        return value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    private var divider: some View {
        Rectangle()
            .fill(RouterTheme.line)
            .frame(width: 1)
            .padding(.vertical, 4)
    }

    // MARK: - Latency and latest turns

    /// Each model's p50 as a marker on a shared scale, with a faint bar out to
    /// its p99, so slow tails read against each other at a glance.
    private var latencyCard: some View {
        let models = monitor.selectedLatencies
        let ceiling = max(models.compactMap { $0.latency?.p99Milliseconds }.max() ?? 1, 1)
        return card(
            title: "Latency",
            hint: monitor.selectedModelID.map { "\($0) · p50 / p99, s" } ?? "p50 / p99, seconds",
            accessory: monitor.selectedModelID == nil ? nil : AnyView(
                Button("Show all") { monitor.selectedModelID = nil }
                    .buttonStyle(.plain)
                    .font(RouterTheme.sans(11.5))
                    .foregroundStyle(RouterTheme.ink2)
            )
        ) {
            if models.isEmpty {
                Text("No latency measurements yet. The proxy reports them once a model has answered.")
                    .font(RouterTheme.sans(11.5))
                    .foregroundStyle(RouterTheme.ink3)
                    .lineLimit(3)
            } else {
                VStack(spacing: 0) {
                    ForEach(models.prefix(4)) { model in
                        if let latency = model.latency {
                            latencyRow(model.id, latency, ceiling: ceiling)
                        }
                    }
                }
            }
        }
        .help("Switchyard measures latency per model since the proxy started; the routing log records token usage only.")
    }

    private func latencyRow(_ id: String, _ latency: RoutingStats.Latency, ceiling: Double) -> some View {
        let tint = ModelFlowPalette.color(for: id, in: monitor.modelIDs)
        return HStack(spacing: 12) {
            HStack(spacing: 7) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(id)
                    .font(RouterTheme.mono(11.5))
                    .foregroundStyle(RouterTheme.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 112, alignment: .leading)

            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Rectangle().fill(RouterTheme.line).frame(height: 1)
                    Capsule()
                        .fill(tint.opacity(0.3))
                        .frame(width: width * latency.p99Milliseconds / ceiling, height: 4)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(tint)
                        .frame(width: 3, height: 12)
                        .offset(x: max(width * latency.p50Milliseconds / ceiling - 1.5, 0))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 14)

            (Text(seconds(latency.p50Milliseconds)).foregroundColor(RouterTheme.ink)
                + Text(" / \(seconds(latency.p99Milliseconds))").foregroundColor(RouterTheme.ink3))
                .font(RouterTheme.sans(11.5))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 78, alignment: .trailing)
        }
        .frame(height: 26)
    }

    /// The newest served turns in the map's scope, with the way into the
    /// full log.
    private func latestTurnsCard(session: RoutingSession?) -> some View {
        let turns = latestTurns(session: session)
        return card(
            title: "Latest turns",
            hint: "routing log",
            accessory: AnyView(
                Button {
                    monitor.pane = .requests
                } label: {
                    HStack(spacing: 3) {
                        Text("All requests")
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .font(RouterTheme.sans(11.5))
                .foregroundStyle(RouterTheme.ink2)
            )
        ) {
            if turns.isEmpty {
                Text(monitor.emptyReason ?? "No routed turns in this scope yet.")
                    .font(RouterTheme.sans(11.5))
                    .foregroundStyle(RouterTheme.ink3)
                    .lineLimit(3)
            } else {
                VStack(spacing: 0) {
                    turnRow(time: Text("Time"), route: Text("Route"), model: Text("Model"),
                            tokens: Text("Tokens"), cached: Text("Cached"), tint: nil, isHeader: true)
                    ForEach(turns, id: \.id) { record in
                        RouterDivider()
                        turnRow(
                            time: Text(record.timestamp?.formatted(date: .omitted, time: .standard) ?? "—"),
                            route: Text(monitor.role(for: record) ?? "—"),
                            model: Text(record.modelIdentity),
                            tokens: Text(record.tokens.total.formatted()),
                            cached: Text(cachedShare(record)),
                            tint: ModelFlowPalette.color(for: record.modelIdentity, in: monitor.modelIDs),
                            isHeader: false
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            monitor.selectedRecordID = record.id
                            monitor.pane = .requests
                        }
                    }
                }
            }
        }
    }

    private func turnRow(
        time: Text, route: Text, model: Text, tokens: Text, cached: Text, tint: Color?, isHeader: Bool
    ) -> some View {
        let small = RouterTheme.sans(11)
        return HStack(spacing: 10) {
            time
                .font(isHeader ? small : RouterTheme.mono(11))
                .foregroundStyle(RouterTheme.ink3)
                .frame(width: 80, alignment: .leading)
            HStack(spacing: 7) {
                if let tint { Circle().fill(tint).frame(width: 6, height: 6) }
                route
            }
            .font(isHeader ? small : RouterTheme.sans(12))
            .foregroundStyle(isHeader ? RouterTheme.ink3 : RouterTheme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            model
                .font(isHeader ? small : RouterTheme.mono(11))
                .foregroundStyle(isHeader ? RouterTheme.ink3 : RouterTheme.ink2)
                .frame(width: 92, alignment: .leading)
            tokens
                .font(isHeader ? small : RouterTheme.sans(12))
                .foregroundStyle(isHeader ? RouterTheme.ink3 : RouterTheme.ink2)
                .frame(width: 60, alignment: .trailing)
            cached
                .font(isHeader ? small : RouterTheme.sans(12))
                .foregroundStyle(RouterTheme.ink3)
                .frame(width: 46, alignment: .trailing)
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .monospacedDigit()
        .frame(height: isHeader ? 20 : 26)
    }

    private func latestTurns(session: RoutingSession?) -> [RoutingLogRecord] {
        var turns: [RoutingLogRecord] = []
        // The log is held newest first; take the first three served turns.
        for record in monitor.records where !record.isClassifier {
            if let session, record.sessionID != session.id { continue }
            turns.append(record)
            if turns.count == 3 { break }
        }
        return turns
    }

    private func cachedShare(_ record: RoutingLogRecord) -> String {
        guard record.tokens.prompt > 0 else { return "—" }
        return percent(Double(record.tokens.cached) / Double(record.tokens.prompt)) + "%"
    }

    private func card<Content: View>(
        title: String, hint: String, accessory: AnyView? = nil, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(title)
                    .font(RouterTheme.sans(13, .semibold))
                    .foregroundStyle(RouterTheme.ink)
                Text(hint)
                    .font(RouterTheme.sans(11.5))
                    .foregroundStyle(RouterTheme.ink3)
                    .lineLimit(1)
                Spacer(minLength: 6)
                accessory
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RouterTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(RouterTheme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func seconds(_ milliseconds: Double) -> String {
        String(format: milliseconds >= 100_000 ? "%.0f" : "%.1f", milliseconds / 1_000)
    }

    // MARK: - Panels

    /// Combined models traffic and proxy lifetime counters panel.
    private func modelsAndProxyPanel(_ metrics: RoutingMetrics) -> some View {
        StatsPanel(
            title: "Models & Proxy",
            note: "\(monitor.flowSession?.shortTitle ?? "15m") traffic · proxy lifetime stats",
            accessory: monitor.stats.map { stats in
                AnyView(
                    Text("\(stats.totalRequests) total reqs · \(stats.totalErrors) err")
                        .font(RouterTheme.mono(10))
                        .foregroundStyle(stats.totalErrors > 0 ? RouterTheme.crit : RouterTheme.ink3)
                )
            }
        ) {
            VStack(spacing: 0) {
                headerRow
                ForEach(metrics.shares) { share in
                    RouterDivider(color: Color(hex: 0xE0F0E8, opacity: 0.045))
                    targetRow(share)
                }

                if let stats = monitor.stats {
                    RouterDivider(color: RouterTheme.line)
                        .padding(.top, 6)
                        .padding(.bottom, 4)

                    proxyCountersSection(stats)
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            column("Model", width: nil, alignment: .leading)
            column("Target", width: 110, alignment: .leading)
            column("Requests", width: 84, alignment: .trailing)
            column("Share", width: 62, alignment: .trailing)
            column("req/s", width: 64, alignment: .trailing)
            column("Errors", width: 50, alignment: .trailing)
        }
        .padding(.bottom, 5)
    }

    private func column(_ text: String, width: CGFloat?, alignment: Alignment) -> some View {
        Text(text.uppercased())
            .font(RouterTheme.mono(9.5, .medium))
            .tracking(0.85)
            .foregroundStyle(RouterTheme.ink3)
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
    }

    private func targetRow(_ share: RoutingMetrics.Share) -> some View {
        let isIdle = share.count == 0
        let errors = monitor.stats?.models.first { $0.id == share.id }?.errors
        let ink = isIdle ? RouterTheme.ink3 : RouterTheme.ink
        let requestsText = share.delegatedCount > 0
            ? "\(share.count) (\(share.delegatedCount) sub)"
            : "\(share.count)"
        return HStack(spacing: 8) {
            Text(share.id)
                .font(RouterTheme.mono(11))
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(monitor.roleName(for: share.target) ?? "—")
                .font(RouterTheme.sans(11.5))
                .foregroundStyle(RouterTheme.ink3)
                .frame(width: 110, alignment: .leading)
            value(requestsText, width: 84, idle: isIdle)
            value(percent(share.share) + "%", width: 62, idle: isIdle)
            value(rate(share.requestsPerSecond), width: 64, idle: isIdle)
            value(errors.map(String.init) ?? "—", width: 50, idle: isIdle, tint: (errors ?? 0) > 0 ? RouterTheme.crit : nil)
        }
        .padding(.vertical, 5)
    }

    private func value(_ text: String, width: CGFloat, idle: Bool, tint: Color? = nil) -> some View {
        Text(text)
            .font(RouterTheme.mono(10.5))
            .foregroundStyle(tint ?? (idle ? RouterTheme.ink3 : RouterTheme.ink2))
            .frame(width: width, alignment: .trailing)
    }

    private func proxyCountersSection(_ stats: RoutingStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("PROXY LIFETIME TOTALS")
                    .font(RouterTheme.mono(9.5, .medium))
                    .tracking(0.7)
                    .foregroundStyle(RouterTheme.ink3)
                Spacer()
                Text("since switchyard-server started")
                    .font(RouterTheme.mono(9.5))
                    .foregroundStyle(RouterTheme.ink3)
            }
            .padding(.top, 2)

            let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                counter("requests", "\(stats.totalRequests)")
                counter("errors", "\(stats.totalErrors)", tint: stats.totalErrors > 0 ? RouterTheme.crit : nil)
                counter("prompt tokens", stats.tokens.prompt.formatted())
                counter("completion tokens", stats.tokens.completion.formatted())
                if stats.tokens.cached > 0 {
                    counter("cached tokens", stats.tokens.cached.formatted())
                }
                counter("overhead p50", "\(milliseconds(stats.overhead.p50Milliseconds)) ms")
                counter("overhead p99", "\(milliseconds(stats.overhead.p99Milliseconds)) ms")
                if stats.classifierRequests > 0 {
                    counter("classifier", "\(stats.classifierRequests)")
                }
                if stats.classifierErrors > 0 {
                    counter("classifier errors", "\(stats.classifierErrors)", tint: RouterTheme.crit)
                }
                ForEach(stats.fallbacks.sorted(by: { $0.key < $1.key }), id: \.key) { name, count in
                    counter("fallback · \(name)", "\(count)")
                }
            }
        }
    }

    private func counter(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(RouterTheme.mono(9, .medium))
                .tracking(0.7)
                .foregroundStyle(RouterTheme.ink3)
            Text(value)
                .font(RouterTheme.mono(11.5))
                .foregroundStyle(tint ?? RouterTheme.ink)
        }
    }

    @ViewBuilder
    private func subagentsPanel(_ metrics: RoutingMetrics) -> some View {
        if metrics.hasSubagentTraffic || metrics.subagentIdentityUnsupported {
            StatsPanel(
                title: "Subagents",
                note: "\(metrics.delegatedCount) calls · \(metrics.uniqueSubagentsCount) subagents · \(metrics.delegatedTokens.formatted()) tokens (\(Int((metrics.delegatedTokenRatio * 100).rounded()))% of volume)"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    if metrics.subagentIdentityUnsupported {
                        HStack(spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(RouterTheme.warn)
                            Text("Harness does not send subagent identity (e.g. Claude Code < 2.1.139). Delegated requests route via parent route.")
                                .font(RouterTheme.sans(11))
                                .foregroundStyle(RouterTheme.ink2)
                        }
                        .padding(8)
                        .background(RouterTheme.warn.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(RouterTheme.warn.opacity(0.25)))
                    }

                    if !metrics.subagentRoles.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ROLES BREAKDOWN")
                                .font(RouterTheme.mono(9.5, .medium))
                                .tracking(0.7)
                                .foregroundStyle(RouterTheme.ink3)
                            HStack(spacing: 8) {
                                ForEach(metrics.subagentRoles.sorted(by: { $0.value > $1.value }), id: \.key) { role, count in
                                    HStack(spacing: 4) {
                                        Text(role)
                                            .font(RouterTheme.mono(11))
                                            .foregroundStyle(RouterTheme.ink)
                                        Text("\(count)")
                                            .font(RouterTheme.mono(10))
                                            .foregroundStyle(RouterTheme.ink3)
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(RouterTheme.panel2, in: RoundedRectangle(cornerRadius: 5))
                                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(RouterTheme.line2))
                                }
                            }
                        }
                    }

                    if !metrics.delegatedShares.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("DELEGATED TRAFFIC BY MODEL")
                                .font(RouterTheme.mono(9.5, .medium))
                                .tracking(0.7)
                                .foregroundStyle(RouterTheme.ink3)
                            ForEach(metrics.delegatedShares) { share in
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(ModelFlowPalette.color(for: share.id, in: monitor.modelIDs))
                                        .frame(width: 6, height: 6)
                                    Text(share.id)
                                        .font(RouterTheme.mono(11))
                                        .foregroundStyle(RouterTheme.ink)
                                    Spacer()
                                    Text("\(share.count) calls")
                                        .font(RouterTheme.mono(10.5))
                                        .foregroundStyle(RouterTheme.ink2)
                                    Text("(\(share.share.formatted(.percent.precision(.fractionLength(0)))))")
                                        .font(RouterTheme.mono(10))
                                        .foregroundStyle(RouterTheme.ink3)
                                    Text("\(share.tokens.formatted()) tok")
                                        .font(RouterTheme.mono(10.5))
                                        .foregroundStyle(RouterTheme.ink2)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Formatting

    private func rate(_ value: Double) -> String {
        value == 0 ? "0" : String(format: value < 0.1 ? "%.4f" : "%.2f", value)
    }

    private func percent(_ fraction: Double) -> String {
        String(format: "%.1f", fraction * 100)
    }

    private func milliseconds(_ value: Double) -> String {
        value >= 100 ? String(Int(value.rounded())) : String(format: "%.1f", value)
    }
}
