import SwitchyardDesktopKit
import SwiftUI

/// Step 3 — what is about to run on the left, what it changes on this Mac on
/// the right, and the generated file behind a disclosure for the people who
/// read it.
struct ConfirmStepView: View {
    @Bindable var model: WizardModel
    var openStatistics: (() -> Void)?
    @State private var showAdvanced = false
    @State private var showPrerequisites = false
    @State private var showConfig = false
    @State private var showDesktopSnippet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                StepHeader(
                    title: "Review and start routing",
                    subtitle: """
                        switchyard-desktop validates this configuration, starts the proxy, and writes a \
                        Codex profile for it. Your own Codex config is left untouched.
                        """
                )
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 12)

                HStack(alignment: .top, spacing: 0) {
                    leftColumn
                        .frame(width: 396, alignment: .topLeading)
                    Rectangle()
                        .fill(RouterTheme.line)
                        .frame(width: 1)
                    rightColumn
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                if !model.processManager.liteLLM.loginMessage.isEmpty {
                    RouterDivider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.processManager.liteLLM.loginMessage)
                            .font(RouterTheme.mono(11))
                            .textSelection(.enabled)
                        Button("Cancel sign-in") { model.processManager.liteLLM.stop() }
                            .buttonStyle(.routerSmall)
                    }
                    .padding(18)
                }
                statusArea
            }
        }
        .task(id: model.readinessFingerprint) {
            await model.refreshReadiness()
        }
    }

    // MARK: - Left: the route that will run

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Route", trailing: "· \(model.profile.tiers.count) targets")
                RouterPanel {
                    VStack(alignment: .leading, spacing: 7) {
                        RouterKeyValue(
                            key: "Algorithm",
                            value: model.profile.algorithm?.displayName ?? "Not selected",
                            monospaced: false
                        )
                        ForEach(model.profile.tiers) { tier in
                            RouterKeyValue(
                                key: tier.displayName,
                                value: tier.assignedModel ?? "—",
                                flag: flag(for: tier)
                            )
                        }
                        RouterDivider()
                        Text(model.routingSummary)
                            .font(RouterTheme.sans(11))
                            .foregroundStyle(RouterTheme.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(model.imageInputSummary)
                            .font(RouterTheme.sans(11))
                            .foregroundStyle(
                                model.declaresImageInput ? RouterTheme.ink3 : RouterTheme.warn
                            )
                            .fixedSize(horizontal: false, vertical: true)
                        Text(model.contextWindowSummary)
                            .font(RouterTheme.sans(11))
                            .foregroundStyle(
                                model.declaresContextWindow ? RouterTheme.ink3 : RouterTheme.warn
                            )
                            .fixedSize(horizontal: false, vertical: true)
                        LongContextToggle(model: model)
                    }
                    .padding(12)
                }
            }

            RouterDisclosurePanel(
                title: "\(passedPrerequisites) of \(prerequisites.count) prerequisites passed",
                glyph: prerequisiteGlyph,
                isExpanded: $showPrerequisites
            ) {
                VStack(spacing: 0) {
                    ForEach(Array(prerequisites.enumerated()), id: \.offset) { index, entry in
                        if index > 0 {
                            RouterDivider(color: Color(hex: 0xE0F0E8, opacity: 0.045))
                        }
                        PrerequisiteRow(label: entry.0, status: entry.1)
                    }
                }
            }

            RouterDisclosurePanel(
                title: "Connection",
                subtitle: "· \(model.profile.provider.displayName.lowercased()) · \(model.profile.host):\(model.profile.port)",
                isExpanded: $showAdvanced
            ) {
                advanced.padding(12)
            }

            if let message = model.recoveryMessage {
                let needsAttention = model.recoveryState.needsAttention
                RouterCallout(
                    title: needsAttention ? "Left over from an earlier run" : "Cleaned up after an earlier run",
                    message: message,
                    tint: needsAttention ? RouterTheme.warn : RouterTheme.ink3,
                    systemImage: needsAttention ? "exclamationmark.shield" : "arrow.uturn.backward"
                )
            }

            if let warning = model.sessionRecordWarning {
                RouterCallout(
                    title: "Automatic cleanup is unavailable",
                    message: warning,
                    tint: RouterTheme.warn,
                    systemImage: "exclamationmark.shield"
                )
            }

            // The generated profile is this app's own file, so it only moves
            // when something outside the app edits or removes it.
            if let drift = model.codexDrift {
                VStack(alignment: .leading, spacing: 8) {
                    RouterCallout(
                        title: drift.title,
                        message: model.codexRepairError.map { "\(drift.message)\n\($0)" } ?? drift.message,
                        tint: RouterTheme.warn,
                        systemImage: "exclamationmark.triangle"
                    )
                    Button(drift.repairTitle) {
                        Task { await model.repairCodexSelection() }
                    }
                    .buttonStyle(.routerSmall)
                    .disabled(model.isBusy)
                }
            }

            if let warning = model.savedSetupWarning {
                RouterCallout(
                    title: "Setup was not saved",
                    message: warning,
                    tint: RouterTheme.warn,
                    systemImage: "exclamationmark.triangle"
                )
            }

            // Said plainly rather than silently: a port that was in use a
            // moment ago is free because this app stopped something.
            if let notice = model.leftoverNotice {
                RouterCallout(
                    title: "Stopped a server left by an earlier run",
                    message: notice,
                    tint: RouterTheme.ink3,
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .padding(.top, 4)
    }

    private var prerequisites: [(String, ReadinessStatus)] {
        [
            ("switchyard-server", model.readiness.binary),
            ("Generated routes", model.readiness.generatedConfig),
            ("Dry-run", model.readiness.dryRun),
            ("Codex profile", model.readiness.codexProfile),
            ("Loopback endpoint", model.readiness.endpoint),
            ("Upstream URL", model.readiness.upstream),
        ]
    }

    private var passedPrerequisites: Int {
        prerequisites.filter { $0.1.isPassed }.count
    }

    private var prerequisiteGlyph: RouterCheckGlyph.Kind {
        if model.readiness.isReady { return .ok }
        return passedPrerequisites == 0 ? .idle : .warn
    }

    private func flag(for tier: TaskTier) -> (text: String, tint: Color)? {
        if model.profile.classifierTargetID == tier.id { return ("classifier", RouterTheme.accent) }
        if model.profile.defaultTargetID == tier.id { return ("fallback", RouterTheme.p95) }
        return nil
    }

    // MARK: - Right: what Start changes on this Mac

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("What Start changes", trailing: "· all of it undone by Stop")
                RouterPanel {
                    VStack(spacing: 0) {
                        changeRow("Routing file", "replaced", model.routingConfigPath.path)
                        RouterDivider()
                        changeRow(
                            "Codex profile", "added",
                            model.codexProfilePath.path
                        )
                        RouterDivider()
                        changeRow(
                            "Your Codex config", "untouched",
                            model.codexConfigPath.path
                        )
                        RouterDivider()
                        changeRow(
                            "Local process", "started",
                            model.profile.needsManagedLiteLLM
                                ? "Switchyard on \(model.profile.host):\(model.profile.port); bundled LiteLLM on 127.0.0.1:4101"
                                : "Switchyard on \(model.profile.host):\(model.profile.port)"
                        )
                        RouterDivider()
                        changeRow("Upstream", "unchanged", model.profile.upstreamBaseURL)
                    }
                }
                Text(upstreamDisclosure)
                    .font(RouterTheme.sans(11))
                    .foregroundStyle(RouterTheme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            RouterDisclosurePanel(
                title: "Generated routes.toml",
                subtitle: configLineCount == 0 ? "· not generated yet" : "· read-only · \(configLineCount) lines",
                isExpanded: $showConfig
            ) {
                ScrollView([.horizontal, .vertical]) {
                    Text(highlightedConfig)
                        .textSelection(.enabled)
                        .lineSpacing(2.5)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 320)
                .background(RouterTheme.sunk)
            }

            CodexDesktopSnippetView(model: model, isExpanded: $showDesktopSnippet)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .padding(.top, 4)
    }

    /// One file or process Start touches: what it is, what happens to it, where.
    private func changeRow(_ key: String, _ effect: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(key)
                        .font(RouterTheme.sans(12, .medium))
                        .foregroundStyle(RouterTheme.ink)
                    RouterFlag(
                        text: effect,
                        tint: effect == "unchanged" ? RouterTheme.ink3 : RouterTheme.accent
                    )
                }
                Text(value)
                    .font(RouterTheme.mono(10))
                    .foregroundStyle(RouterTheme.ink3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var configLineCount: Int {
        model.configPreview.isEmpty ? 0 : model.configPreview.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private var highlightedConfig: AttributedString {
        let preview = model.configPreview
        guard !preview.isEmpty else {
            var placeholder = AttributedString(
                "The generated file appears once every role has a discovered model."
            )
            placeholder.font = RouterTheme.mono(10.5)
            placeholder.foregroundColor = RouterTheme.ink3
            return placeholder
        }
        return TOMLHighlighter.highlight(preview, font: RouterTheme.mono(10.5))
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Proxy port") {
                TextField("Port", value: $model.profile.port, format: .number.grouping(.never))
                    .frame(width: 88)
            }
            field("Upstream base URL") {
                TextField(Provider.codex.defaultUpstreamBaseURL, text: $model.profile.upstreamBaseURL)
            }
            field("switchyard-server") {
                TextField(
                    model.resolvedBinary?.path ?? "Bundled server unavailable — reinstall switchyard-desktop",
                    text: $model.binaryPathOverride
                )
            }
            field("Codex model") {
                Text(model.profile.routeID)
                    .font(RouterTheme.mono(11))
                    .foregroundStyle(RouterTheme.ink2)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $model.profile.advertisesReasoningSummaries) {
                    Text("Use Codex reasoning summary settings")
                        .font(RouterTheme.sans(11.5))
                        .foregroundStyle(RouterTheme.ink)
                }
                .toggleStyle(.checkbox)
                Text(
                    """
                    Leave your existing Codex summary preference alone. Turn this off when a \
                    model supports reasoning but cannot return a summary: the generated profile \
                    then asks for no summary, for routed sessions only.
                    """
                )
                .font(RouterTheme.sans(10.5))
                .foregroundStyle(RouterTheme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            }

            RouterNote(
                systemImage: "exclamationmark.triangle",
                text: """
                    Port \(RoutingProfile.reservedPort) is reserved for another Switchyard \
                    instance on this machine.
                    """,
                tint: RouterTheme.warn
            )
        }
        .textFieldStyle(.roundedBorder)
        .font(RouterTheme.mono(11))
    }

    private func field<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(RouterTheme.mono(10, .medium))
                .tracking(0.6)
                .foregroundStyle(RouterTheme.ink3)
            content()
        }
    }

    private var upstreamDisclosure: String {
        if model.profile.usesManagedLiteLLM { return managedUpstreamDisclosure }
        if model.profile.routesJudgeThroughLiteLLM { return judgeUpstreamDisclosure }
        return externalUpstreamDisclosure
    }

    /// Served turns and the classifier call take different paths, so both are named.
    private var judgeUpstreamDisclosure: String {
        """
        Switchyard routes requests through the independently managed upstream at \
        \(model.profile.upstreamBaseURL). The classifier call goes through the bundled LiteLLM \
        proxy instead, because that upstream rejects the request Switchyard builds for it; LiteLLM \
        uses its own ChatGPT sign-in and stores the OAuth session in ~/.config/litellm/chatgpt. \
        Stop removes the generated Codex profile and stops both local servers.
        """
    }

    private var managedUpstreamDisclosure: String {
        """
        Switchyard routes requests through the bundled LiteLLM proxy. LiteLLM uses its own ChatGPT \
        sign-in and stores the OAuth session in ~/.config/litellm/chatgpt. Request contents are sent \
        to ChatGPT and are not logged by switchyard-desktop. Stop removes the generated Codex profile and stops \
        both local servers.
        """
    }

    private var externalUpstreamDisclosure: String {
        """
        Switchyard routes requests through the independently managed upstream at \
        \(model.profile.upstreamBaseURL). switchyard-desktop does not start, authenticate, or stop that \
        service. Stop removes the generated Codex profile and stops only the Switchyard process \
        started by switchyard-desktop.
        """
    }

    // MARK: - Apply state

    @ViewBuilder
    private var statusArea: some View {
        switch model.applyState {
        case .idle:
            EmptyView()
        case .working(let message):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message)
                    .font(RouterTheme.bodySmall)
                    .foregroundStyle(RouterTheme.ink2)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        case .applied(let configPath, let profilePath):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    RouterCheckGlyph(kind: .ok, size: 12)
                    Text("The route is running on \(model.profile.host):\(model.profile.port).")
                        .font(RouterTheme.bodySmall)
                        .foregroundStyle(RouterTheme.accent)
                    if let openStatistics {
                        Button("Open statistics", action: openStatistics)
                            .buttonStyle(.routerSmall)
                    }
                }
                CodexLaunchCommandRow()
                Text("Routing config: \(configPath)")
                    .font(RouterTheme.mono(10))
                    .foregroundStyle(RouterTheme.ink3)
                    .textSelection(.enabled)
                Text("Codex profile: \(profilePath)")
                    .font(RouterTheme.mono(10))
                    .foregroundStyle(RouterTheme.ink3)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                RouterCallout(title: "Could not start routing", message: message)
                // What the servers themselves printed is kept on disk, and is
                // usually the part that explains a failure the app can only
                // report second-hand.
                HStack(spacing: 8) {
                    Button("Reveal logs in Finder") { AppDelegate.revealLogs() }
                        .buttonStyle(.routerSmall)
                    Text(DiagnosticLog.shared.url.deletingLastPathComponent().path)
                        .font(RouterTheme.mono(10))
                        .foregroundStyle(RouterTheme.ink3)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }
}

/// One prerequisite line inside the collapsible summary.
private struct PrerequisiteRow: View {
    let label: String
    let status: ReadinessStatus

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            RouterCheckGlyph(kind: glyph, size: 12)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(RouterTheme.sans(12, .medium))
                    .foregroundStyle(RouterTheme.ink)
                Text(status.message)
                    .font(RouterTheme.mono(10.5))
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
    }

    private var glyph: RouterCheckGlyph.Kind {
        switch status {
        case .passed: .ok
        case .failed: .fail
        case .skipped: .warn
        case .pending: .idle
        }
    }

    private var tint: Color {
        switch status {
        case .failed: RouterTheme.crit
        case .skipped: RouterTheme.warn
        default: RouterTheme.ink3
        }
    }
}
