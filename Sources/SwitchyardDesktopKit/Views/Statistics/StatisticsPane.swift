import SwiftUI

/// Where requests went: headline rates, latency percentiles over time, the
/// share each model served, and a per-target table. Everything here is computed
/// from the durable routing log plus the proxy's own counters.
package struct StatisticsPane: View {
    @Bindable var monitor: RoutingMonitor

    package var body: some View {
        ScrollView {
            let metrics = monitor.activityMetrics

            VStack(alignment: .leading, spacing: 10) {
                PaneHeader(eyebrow: "Live model activity", title: "Where requests go") {
                    EmptyView()
                }

                kpis(metrics)

                RequestFlowView(
                    metrics: metrics, modelIDs: monitor.modelIDs, isRouting: monitor.isRouting,
                    sessions: monitor.sessions, asOf: monitor.lastRefresh,
                    usesClassifier: monitor.usesClassifier,
                    classifierModelID: monitor.classifierModelID,
                    contextUsage: monitor.sessionContextUsage,
                    contextSession: monitor.contextSession,
                    activeSessionIDs: monitor.activeSessionIDs,
                    routeContextWindow: monitor.sessionRouteContextWindow,
                    roles: monitor.flowRoles,
                    selectedModelID: $monitor.selectedModelID,
                    selectedSessionID: $monitor.selectedSessionID
                )

                modelFilters
                performancePanel(monitor.selectedModelMetrics)
                modelsAndProxyPanel(metrics)
                subagentsPanel(metrics)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    // MARK: - KPIs

    private func kpis(_ metrics: RoutingMetrics) -> some View {
        HStack(spacing: 0) {
            KPITile(
                label: "Requests",
                value: rate(metrics.requestsPerSecond),
                unit: "req/s",
                subtitle: servedSubtitle(metrics)
            )
            divider
            KPITile(
                label: "Model errors",
                value: monitor.stats.map { String($0.totalErrors) } ?? "—",
                subtitle: "since router started",
                // A failing judge never shows up here: the route keeps serving
                // its default target, so name it where the errors are read.
                highlight: monitor.classifierFailure ?? fallbackHighlight
            )
            divider
            KPITile(
                label: "Tokens processed",
                value: metrics.tokens.formatted(.number.notation(.compactName)),
                unit: "tok",
                subtitle: tokensSubtitle(metrics)
            )
            divider
            KPITile(
                label: "Cache efficiency",
                value: cacheEfficiency(metrics),
                subtitle: cacheSubtitle(metrics)
            )
            divider
            costTile(monitor.sessionCost)
        }
        .padding(10)
        .background(RouterTheme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(RouterTheme.line2, lineWidth: 1))
    }

    /// When Switchyard fell back because the primary model failed, the error
    /// KPI names which fallback took over so the operator sees the failover.
    private var fallbackHighlight: String? {
        guard let stats = monitor.stats else { return nil }
        let active = stats.fallbacks.filter { $0.value > 0 }
        guard let first = active.keys.sorted().first else { return nil }
        return "fallback: \(first)"
    }

    private func servedSubtitle(_ metrics: RoutingMetrics) -> String {
        let scope = monitor.flowSession == nil ? MetricsRange.fifteenMinutes.label : "session"
        let total = "\(metrics.count) served in \(scope)"
        guard let seconds = metrics.secondsPerRequest else { return total }
        return "\(total) · 1 every \(String(format: "%.1f", seconds))s"
    }

    private func tokensSubtitle(_ metrics: RoutingMetrics) -> String {
        guard metrics.count > 0 else { return "none in window" }
        let average = metrics.tokens / metrics.count
        return "\(average.formatted()) avg / turn"
    }

    private func cacheEfficiency(_ metrics: RoutingMetrics) -> String {
        // `tokens` is the whole prompt Switchyard sent — cached tokens already
        // counted once inside it, not on top of it — so this is the fraction
        // of the prompt that was a cache hit, not a fraction over-counting it.
        guard metrics.tokens > 0 else { return "—" }
        let fraction = Double(metrics.cachedTokens) / Double(metrics.tokens)
        return percent(fraction) + "%"
    }

    private func cacheSubtitle(_ metrics: RoutingMetrics) -> String {
        guard metrics.cachedTokens > 0 else { return "no cache hits in window" }
        return "\(metrics.cachedTokens.formatted(.number.notation(.compactName))) cached tokens"
    }

    /// Approximate spend for the flow map's conversation at API list prices.
    /// Tokens on a model LiteLLM has no price for are named, not guessed.
    private func costTile(_ cost: TokenCostEstimate) -> some View {
        let session = monitor.flowSession
        let hasPrice = cost.pricedCalls > 0
        let unpriced = cost.unpricedModels.first.map { first in
            cost.unpricedModels.count == 1 ? first : "\(first) +\(cost.unpricedModels.count - 1)"
        }
        let subtitle: String
        if cost.isEmpty {
            subtitle = "no calls in session"
        } else if !hasPrice {
            subtitle = "no list price for"
        } else {
            // The full price basis is in the tooltip; the tile keeps one line.
            subtitle = unpriced == nil ? "at API list price" : "excl."
        }
        return KPITile(
            label: session == nil ? "Est. cost" : "Session cost",
            value: hasPrice ? dollars(cost.dollars) : "—",
            unit: hasPrice ? "est." : nil,
            subtitle: subtitle,
            highlight: unpriced
        )
        .help(costHelp(cost, session: session))
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

    // MARK: - Panels

    /// Filter pills that let the operator isolate one model's latency and
    /// sparkline without having to click the node in the diagram.
    private var modelFilters: some View {
        HStack(spacing: 6) {
            Text("Filter:")
                .font(RouterTheme.mono(10.5))
                .foregroundStyle(RouterTheme.ink3)

            filterPill(id: nil, title: "All models", count: monitor.activityMetrics.count)

            ForEach(monitor.activityMetrics.shares) { share in
                filterPill(id: share.id, title: share.id, count: share.count)
            }
            Spacer()
        }
    }

    private func filterPill(id: String?, title: String, count: Int) -> some View {
        let selected = monitor.selectedModelID == id
        return Button {
            monitor.selectedModelID = id
        } label: {
            HStack(spacing: 5) {
                if let id {
                    Circle()
                        .fill(ModelFlowPalette.color(for: id, in: monitor.modelIDs))
                        .frame(width: 6, height: 6)
                }
                Text(title)
                    .font(RouterTheme.mono(10.5))
                    .foregroundStyle(selected ? RouterTheme.ink : RouterTheme.ink2)
                Text("\(count)")
                    .font(RouterTheme.mono(9.5))
                    .foregroundStyle(RouterTheme.ink3)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(selected ? RouterTheme.accent.opacity(0.12) : RouterTheme.panel2, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? RouterTheme.accent.opacity(0.5) : RouterTheme.line2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Combined latency and turns activity panel, saving vertical space by placing
    /// lifetime latency percentiles side-by-side with the durable log's activity sparkline.
    private func performancePanel(_ metrics: RoutingMetrics) -> some View {
        StatsPanel(
            title: "Latency & Routed turns",
            note: "\(monitor.range.label) history · latency since start",
            accessory: AnyView(
                Text("\(metrics.count) turns · \(metrics.tokens.formatted(.number.notation(.compactName))) tokens")
                    .font(RouterTheme.mono(10))
                    .foregroundStyle(RouterTheme.ink3)
            )
        ) {
            HStack(alignment: .top, spacing: 18) {
                // Left column: End-to-end latency
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("LATENCY")
                            .font(RouterTheme.mono(9.5, .medium))
                            .tracking(0.7)
                            .foregroundStyle(RouterTheme.ink3)
                        Spacer()
                        Text("milliseconds")
                            .font(RouterTheme.mono(9.5))
                            .foregroundStyle(RouterTheme.ink3)
                    }

                    let models = monitor.selectedLatencies
                    if models.isEmpty {
                        Text("No latency measurements for this selection yet.")
                            .font(RouterTheme.mono(10.5))
                            .foregroundStyle(RouterTheme.ink3)
                            .padding(.vertical, 6)
                    } else {
                        VStack(spacing: 5) {
                            ForEach(models) { model in
                                if let latency = model.latency {
                                    HStack(spacing: 10) {
                                        Circle()
                                            .fill(ModelFlowPalette.color(for: model.id, in: monitor.modelIDs))
                                            .frame(width: 6, height: 6)
                                        Text(model.id)
                                            .font(RouterTheme.mono(11))
                                            .foregroundStyle(RouterTheme.ink)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 6)
                                        legend("p50", latency.p50Milliseconds, RouterTheme.p50)
                                        legend("p99", latency.p99Milliseconds, RouterTheme.p99)
                                    }
                                    .padding(.vertical, 3)
                                }
                            }
                        }
                    }

                    Text("Switchyard measures latency in aggregate; routing log records token usage only.")
                        .font(RouterTheme.mono(9.5))
                        .foregroundStyle(RouterTheme.ink3)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Divider between columns
                Rectangle()
                    .fill(RouterTheme.line)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)

                // Right column: Routed turns sparkline
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        HStack(spacing: 6) {
                            Text("ROUTED TURNS")
                                .font(RouterTheme.mono(9.5, .medium))
                                .tracking(0.7)
                            Text("5 min intervals")
                                .font(RouterTheme.mono(9.5))
                        }
                        .foregroundStyle(RouterTheme.ink3)
                        Spacer()
                        Text(monitor.selectedModelID ?? "All models")
                            .font(RouterTheme.mono(9.5))
                            .foregroundStyle(RouterTheme.ink2)
                    }

                    if metrics.count == 0 {
                        StatsEmptyState(message: "No routed turns for this selection yet.")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 4) {
                            Sparkline(values: metrics.buckets.map { Double($0.count) }, tint: RouterTheme.accent)
                                .frame(height: 52)
                            HStack {
                                Text(metrics.windowStart.formatted(date: .omitted, time: .shortened))
                                Spacer()
                                Text(metrics.windowEnd.formatted(date: .omitted, time: .shortened))
                            }
                            .font(RouterTheme.mono(9.5))
                            .foregroundStyle(RouterTheme.ink3)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 2)
        }
    }

    private func legend(_ name: String, _ value: Double?, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1)
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(name)
                .font(RouterTheme.sans(10.5))
                .foregroundStyle(RouterTheme.ink2)
            Text(value.map { milliseconds($0) } ?? "—")
                .font(RouterTheme.mono(10, .medium))
                .foregroundStyle(RouterTheme.ink)
        }
    }

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
