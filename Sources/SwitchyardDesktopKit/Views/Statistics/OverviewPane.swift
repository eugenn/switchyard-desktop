import SwiftUI

/// What is running right now, the profile serving it, and the safety net behind
/// it — plus the controls that stop or undo the route.
package struct OverviewPane: View {
    @Bindable var monitor: RoutingMonitor
    package var openSetup: (() -> Void)?
    @State private var showDesktopSnippet = false

    private var model: WizardModel { monitor.model }

    package var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                PaneHeader(eyebrow: "Routing atlas", title: title) {
                    if monitor.isRouting || model.isApplied {
                        Button("Stop routing") {
                            Task { await model.revert() }
                        }
                        .buttonStyle(.router)
                        .disabled(model.isBusy)
                        .help("Restores the captured Codex configuration, then stops the proxy.")
                    } else if let openSetup {
                        Button("Open setup", action: openSetup)
                            .buttonStyle(.routerPrimary)
                    }
                }

                statusBand

                HStack(alignment: .top, spacing: 10) {
                    profilePanel
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                    VStack(spacing: 10) {
                        windowPanel
                        safetyPanel
                    }
                    .frame(width: 320)
                }

                recentPanel
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var title: String {
        if monitor.isRouting { return "Routing is on" }
        return model.recoveryState.needsAttention ? "Needs attention" : "Routing is off"
    }

    // MARK: - Status band

    private var statusBand: some View {
        HStack(spacing: 0) {
            bandCell {
                HStack(spacing: 7) {
                    RouterDot(
                        color: monitor.isRouting ? RouterTheme.accent : RouterTheme.idle,
                        halo: monitor.isRouting
                    )
                    if let uptime = monitor.uptime, let started = model.routingStartedAt {
                        Text("Active for \(uptime)")
                            .font(RouterTheme.sans(12, .semibold))
                            .foregroundStyle(RouterTheme.ink)
                        Text("since \(started.formatted(date: .omitted, time: .shortened))")
                            .font(RouterTheme.mono(10.5))
                            .foregroundStyle(RouterTheme.ink2)
                    } else {
                        Text("No active route")
                            .font(RouterTheme.sans(12, .medium))
                            .foregroundStyle(RouterTheme.ink2)
                    }
                }
            }
            bandCell { keyValue("proxy", "\(model.profile.host):\(model.profile.port)") }
            bandCell { keyValue("codex model", model.profile.routeID) }
            bandCell { keyValue("process", processDescription) }
        }
        .background(RouterTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(RouterTheme.line, lineWidth: 1)
        )
    }

    private func bandCell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(RouterTheme.line)
                    .frame(width: 1)
            }
    }

    private func keyValue(_ key: String, _ value: String) -> some View {
        HStack(spacing: 7) {
            Text(key)
                .font(RouterTheme.mono(9.5, .medium))
                .tracking(0.7)
                .foregroundStyle(RouterTheme.ink3)
            Text(value)
                .font(RouterTheme.mono(10.5))
                .foregroundStyle(RouterTheme.ink)
                .textSelection(.enabled)
        }
    }

    private var processDescription: String {
        if case .running(let pid, _) = model.processManager.status {
            return "switchyard-server · pid \(pid)"
        }
        return "not running"
    }

    // MARK: - Panels

    private var profilePanel: some View {
        StatsPanel(
            title: "Active profile",
            note: profileNote
        ) {
            VStack(spacing: 0) {
                ForEach(model.profile.tiers) { tier in
                    assignmentRow(tier)
                }
                if model.profile.tiers.isEmpty {
                    Text("No routing roles configured yet.")
                        .font(RouterTheme.bodySmall)
                        .foregroundStyle(RouterTheme.ink3)
                        .padding(.vertical, 6)
                }
            }

            HStack(spacing: 14) {
                Button("Open statistics") { monitor.pane = .statistics }
                    .buttonStyle(.routerGhost)
                if let openSetup {
                    Button("Change in Routing config", action: openSetup)
                        .buttonStyle(.routerGhost)
                }
            }
            .padding(.top, 4)
        }
    }

    private var profileNote: String {
        let algorithm = model.profile.algorithm?.displayName.lowercased() ?? "no algorithm"
        return "\(algorithm) · \(model.profile.tiers.count) targets"
    }

    private func assignmentRow(_ tier: TaskTier) -> some View {
        let served = monitor.metrics.shares.first { $0.id == tier.assignedModel }?.count ?? 0
        let isIdle = served == 0
        return HStack(spacing: 7) {
            Text(tier.displayName)
                .font(RouterTheme.sans(12))
                .foregroundStyle(isIdle ? RouterTheme.ink3 : RouterTheme.ink)
            if model.profile.classifierTargetID == tier.id {
                RouterFlag(text: "classifier")
            }
            if model.profile.defaultTargetID == tier.id {
                RouterFlag(text: "fallback", tint: RouterTheme.p95)
            }
            Spacer(minLength: 8)
            Text(tier.assignedModel ?? "—")
                .font(RouterTheme.mono(10.5))
                .foregroundStyle(isIdle ? RouterTheme.ink3 : RouterTheme.ink2)
        }
        .padding(.vertical, 4)
    }

    private var windowPanel: some View {
        StatsPanel(title: monitor.range.name.capitalizedFirst, note: nil) {
            let metrics = monitor.metrics
            HStack(alignment: .top, spacing: 16) {
                miniValue("\(metrics.count)", "requests served")
                miniValue(monitor.stats.map { String($0.totalErrors) } ?? "—", "model errors")
                // The proxy measures latency; the log has none to window.
                let latency = monitor.stats?.models.compactMap(\.latency).first
                miniValue(
                    latency.map { "\(Int($0.p50Milliseconds.rounded()))" } ?? "—",
                    "p50 latency",
                    unit: latency == nil ? nil : "ms"
                )
            }
            if let failure = monitor.classifierFailure {
                Text("\(failure) — every turn fell back to the default target")
                    .font(RouterTheme.mono(10))
                    .foregroundStyle(RouterTheme.crit)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let stats = monitor.stats, stats.tokens.total > 0 {
                Text("\(stats.tokens.total.formatted()) tokens since the proxy started")
                    .font(RouterTheme.mono(10))
                    .foregroundStyle(RouterTheme.ink3)
            }
        }
    }

    private func miniValue(_ value: String, _ label: String, unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(RouterTheme.sans(18, .semibold))
                    .foregroundStyle(RouterTheme.ink)
                if let unit {
                    Text(unit)
                        .font(RouterTheme.sans(11, .medium))
                        .foregroundStyle(RouterTheme.ink2)
                }
            }
            Text(label)
                .font(RouterTheme.mono(9.5))
                .foregroundStyle(RouterTheme.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var safetyPanel: some View {
        StatsPanel(title: "Safety") {
            VStack(alignment: .leading, spacing: 6) {
                Text("GENERATED CODEX PROFILE")
                    .font(RouterTheme.mono(9.5, .medium))
                    .tracking(0.8)
                    .foregroundStyle(RouterTheme.ink3)
                Text(model.installedProfilePath ?? "Not written — no route is active.")
                    .font(RouterTheme.mono(10))
                    .foregroundStyle(RouterTheme.ink2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    """
                    Stop deletes that file and the local proxy. Your own Codex configuration \
                    beside it is never modified, so an unexpected quit cannot leave it broken.
                    """
                )
                .font(RouterTheme.sans(11))
                .foregroundStyle(RouterTheme.ink3)
                .fixedSize(horizontal: false, vertical: true)
                CodexLaunchCommandRow(
                    caption: "Restart a routed session after changing the route."
                )
                CodexDesktopSnippetView(model: model, isExpanded: $showDesktopSnippet)
            }
        }
    }

    private var recentPanel: some View {
        StatsPanel(
            title: "Recent decisions",
            note: "last \(min(monitor.records.count, 3)) turns",
            accessory: AnyView(
                Button("See all requests") { monitor.pane = .requests }
                    .buttonStyle(.routerGhost)
            )
        ) {
            if let reason = monitor.emptyReason {
                StatsEmptyState(message: reason, systemImage: "clock.arrow.circlepath")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(monitor.records.prefix(3))) { record in
                        HStack(spacing: 12) {
                            Text(record.timestamp?.formatted(date: .omitted, time: .standard) ?? "—")
                                .font(RouterTheme.mono(10.5))
                                .foregroundStyle(RouterTheme.ink3)
                                .frame(width: 76, alignment: .leading)
                            Text(monitor.role(for: record) ?? "—")
                                .font(RouterTheme.sans(12))
                                .foregroundStyle(record.isClassifier ? RouterTheme.ink3 : RouterTheme.ink)
                                .frame(width: 130, alignment: .leading)
                            Text(record.model ?? "—")
                                .font(RouterTheme.mono(10.5))
                                .foregroundStyle(RouterTheme.ink2)
                            Spacer(minLength: 8)
                            Text("\(record.tokens.total.formatted(.number.notation(.compactName))) tok")
                                .font(RouterTheme.mono(10))
                                .foregroundStyle(RouterTheme.ink3)
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
        }
    }
}

package extension String {
    package var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
