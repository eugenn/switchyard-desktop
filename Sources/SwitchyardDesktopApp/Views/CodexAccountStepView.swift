import SwitchyardDesktopKit
import SwiftUI

/// Step 1 — one answer to one question: what can this Codex account route?
/// The checks that must pass are on the left, and the models they produce are
/// on the right, so the cause and its result are never a page apart.
struct CodexAccountStepView: View {
    @Bindable var model: WizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                title: "Your Codex account",
                subtitle: """
                    switchyard-desktop reads your existing Codex setup and asks Codex which subscription \
                    models are available. Only those models can be routed.
                    """
            )
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            HStack(alignment: .top, spacing: 0) {
                checksColumn
                    .frame(width: 420, alignment: .topLeading)
                Rectangle()
                    .fill(RouterTheme.line)
                    .frame(width: 1)
                modelsColumn
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - Left: the checks

    private var checksColumn: some View {
        ScrollView {
            let preflight = model.preflight

            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Setup checks", trailing: "· \(passedChecks) of \(preflight.checks.count) passed")
                RouterPanel {
                    VStack(spacing: 0) {
                        ForEach(Array(preflight.checks.enumerated()), id: \.element.id) { index, check in
                            if index > 0 { RouterDivider() }
                            CheckRow(check: check)
                        }
                    }
                }

                if let fix = preflight.fix {
                    RouterCallout(title: fix.title, message: fix.message)
                }

                if let warning = model.savedSetupWarning {
                    RouterCallout(
                        title: "Saved setup needs attention",
                        message: warning,
                        tint: RouterTheme.warn,
                        systemImage: "exclamationmark.triangle"
                    )
                }

                if !model.groupsWithSavedSetup.isEmpty {
                    RouterCallout(
                        title: "\(model.groupsWithSavedSetup.count) project setup"
                            + (model.groupsWithSavedSetup.count == 1 ? "" : "s") + " saved",
                        message: "Load one on the next step, under Choose routing roles.",
                        tint: RouterTheme.accent,
                        systemImage: "folder"
                    )
                }

                HStack(spacing: 10) {
                    Button(preflight.actionTitle) {
                        Task { await model.refreshSubscriptionModels() }
                    }
                    .buttonStyle(.router)
                    .disabled(!preflight.actionEnabled || !model.canRefreshDiscovery)

                    Text("read from \(model.codexConfigPath.path)")
                        .font(RouterTheme.mono(10))
                        .foregroundStyle(RouterTheme.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(model.codexConfigPath.path)
                }

                if let blocker = model.discoveryRefreshBlocker {
                    RouterNote(
                        systemImage: "arrow.triangle.branch",
                        text: blocker,
                        tint: RouterTheme.ink2
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .padding(.top, 4)
        }
    }

    private var passedChecks: Int {
        model.preflight.checks.filter { $0.outcome == .passed }.count
    }

    // MARK: - Right: what those checks produced

    private var modelsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    SectionLabel("Models on this account", trailing: "· \(model.discoveredModels.count) found")
                    Spacer(minLength: 8)
                    Text(discoveryCaption)
                        .font(RouterTheme.mono(10))
                        .foregroundStyle(RouterTheme.ink3)
                    Button("Refresh") {
                        Task { await model.refreshSubscriptionModels() }
                    }
                    .buttonStyle(.routerSmall)
                    .disabled(!model.canRefreshDiscovery)
                    .help(model.discoveryRefreshBlocker ?? "Ask Codex for its model list again")
                }

                RouterPanel {
                    VStack(spacing: 0) {
                        if model.discoveredModels.isEmpty {
                            emptyRow
                        } else {
                            ForEach(Array(model.discoveredModels.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { RouterDivider() }
                                ModelRow(entry: entry)
                            }
                        }
                    }
                }

                RouterNote(
                    systemImage: "checkmark.shield",
                    text: """
                        switchyard-desktop does not accept API keys or manually entered model IDs, and it \
                        never reads credentials out of the Codex configuration. Refresh before \
                        starting if your subscription access changes.
                        """
                )
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .padding(.top, 4)
        }
    }

    private var emptyRow: some View {
        HStack(spacing: 9) {
            RouterCheckGlyph(kind: model.isDiscovering ? .working : .idle, size: 12)
            Text(
                model.isDiscovering
                    ? "Asking Codex which models your subscription can use…"
                    : model.discoveryState.blockingMessage
            )
            .font(RouterTheme.bodySmall)
            .foregroundStyle(RouterTheme.ink2)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var discoveryCaption: String {
        guard let discoveredAt = model.discoveredAt else {
            return "not discovered yet"
        }
        return "discovered \(discoveredAt.formatted(date: .omitted, time: .standard))"
    }
}

/// One preflight row: status glyph, label with its detail, and the value column.
private struct CheckRow: View {
    let check: CodexPreflight.Check

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            RouterCheckGlyph(kind: glyph, size: 12)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .font(RouterTheme.sans(12.5, .medium))
                    .foregroundStyle(check.outcome == .notChecked ? RouterTheme.ink3 : RouterTheme.ink)
                Text(check.detail)
                    .font(RouterTheme.sans(11))
                    .foregroundStyle(detailTint)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 10)

            Text(check.value)
                .font(RouterTheme.mono(10.5))
                .foregroundStyle(valueTint)
                .padding(.top, 1)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var glyph: RouterCheckGlyph.Kind {
        switch check.outcome {
        case .passed: .ok
        case .failed: .fail
        case .working: .working
        case .notChecked: .idle
        }
    }

    private var detailTint: Color {
        check.outcome == .failed ? RouterTheme.crit : RouterTheme.ink3
    }

    private var valueTint: Color {
        switch check.outcome {
        case .failed: RouterTheme.crit
        case .notChecked: RouterTheme.idle
        default: RouterTheme.ink2
        }
    }
}

/// One discovered subscription model.
private struct ModelRow: View {
    let entry: CodexSubscriptionModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName ?? entry.id)
                    .font(RouterTheme.sans(12.5, .medium))
                    .foregroundStyle(RouterTheme.ink)
                Text(entry.id)
                    .font(RouterTheme.mono(10.5))
                    .foregroundStyle(RouterTheme.ink3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if !entry.supportsImages {
                RouterTag(text: "text only", tint: RouterTheme.warn)
            }
            if entry.isDefault {
                RouterTag(text: "default")
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
