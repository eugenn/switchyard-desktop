import AppKit
import SwitchyardDesktopKit
import SwiftUI

/// Root of the routing editor: a navigable step rail across the top, the current
/// step's content, and one footer that carries the state and the action that
/// moves forward.
struct WizardView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Bindable var model: WizardModel
    /// Opens the statistics window once a route is live.
    var openStatistics: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(model: model)
            RouterDivider()

            Group {
                switch model.step {
                case .provider: CodexAccountStepView(model: model)
                case .tiers: TierAssignmentStepView(model: model)
                case .confirm: ConfirmStepView(model: model, openStatistics: openStatistics)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            RouterDivider()
            footer
        }
        .background(RouterTheme.win)
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 940, minHeight: 700)
        .task {
            await model.discoverSubscriptionModelsIfNeeded()
        }
        .onChange(of: model.applyState) { _, state in
            if case .applied = state {
                openStatistics?()
                dismissWindow(id: SwitchyardDesktopApp.setupWindowID)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if model.step == .confirm {
                proxyState
                if let blocker = model.startBlocker {
                    FooterState(glyph: .warn, message: blocker, tint: RouterTheme.warn)
                }
            } else {
                footerState
            }

            Spacer(minLength: 12)

            if model.step == .confirm, model.hasSavedSetup,
               !model.isApplied, !model.processManager.status.isRunning {
                Button("Reconfigure", action: model.reconfigure)
                    .buttonStyle(.router)
            }

            Button("Back", action: model.back)
                .buttonStyle(.router)
                .disabled(!model.canGoBack)

            if model.step == .confirm {
                if model.isApplied || model.processManager.status.isRunning {
                    Button("Stop routing") {
                        Task { await model.revert() }
                    }
                    .buttonStyle(.router)
                    .disabled(model.isBusy)
                }
                if !model.isApplied {
                    Button("Start routing") {
                        Task { await model.apply() }
                    }
                    .buttonStyle(.routerPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStartRouting)
                }
            } else {
                Button("Next", action: model.next)
                    .buttonStyle(.routerPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canAdvance)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Color.white.opacity(0.012))
    }

    /// Live proxy indicator, shown beside the button that starts it.
    private var proxyState: some View {
        let running = model.processManager.status.isRunning
        return HStack(spacing: 7) {
            RouterDot(color: running ? RouterTheme.accent : RouterTheme.idle, halo: running)
            Text(running ? "Proxy running" : "Proxy stopped")
                .font(RouterTheme.bodySmall)
                .foregroundStyle(running ? RouterTheme.ink : RouterTheme.ink2)
        }
    }

    @ViewBuilder
    private var footerState: some View {
        switch model.step {
        case .provider:
            if let blocker = model.advanceBlocker {
                FooterState(
                    glyph: model.preflight.summaryOutcome == .working ? .working : .fail,
                    message: blocker,
                    tint: RouterTheme.crit
                )
            } else {
                FooterState(
                    glyph: .ok,
                    message: "\(model.discoveredModels.count) models available — assign them to routing roles next.",
                    tint: RouterTheme.ink2
                )
            }
        case .tiers:
            if let blocker = model.advanceBlocker {
                FooterState(glyph: .warn, message: blocker, tint: RouterTheme.warn)
            } else {
                FooterState(
                    glyph: .ok,
                    message: "All roles assigned. Review runs Switchyard's dry-run before anything starts.",
                    tint: RouterTheme.ink2
                )
            }
        case .confirm:
            EmptyView()
        }
    }
}

/// Icon plus one line of state, shown at the left of every wizard footer.
struct FooterState: View {
    let glyph: RouterCheckGlyph.Kind
    let message: String
    var tint: Color = RouterTheme.ink2

    var body: some View {
        HStack(spacing: 7) {
            RouterCheckGlyph(kind: glyph, size: 12)
            Text(message)
                .font(RouterTheme.bodySmall)
                .foregroundStyle(tint)
                .lineLimit(2)
        }
    }
}

/// Numbered rail across the top. Every step the current one has already cleared
/// is a button, so a finished setup can be edited without walking the flow.
private struct StepIndicator: View {
    @Bindable var model: WizardModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(WizardModel.Step.allCases) { step in
                stepButton(step)
                if step != WizardModel.Step.allCases.last {
                    Rectangle()
                        .fill(step.rawValue < model.step.rawValue ? RouterTheme.accent.opacity(0.35) : RouterTheme.line)
                        .frame(height: 1)
                        .frame(minWidth: 12)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Step \(model.step.rawValue + 1) of \(WizardModel.Step.allCases.count): \(model.step.title)"
        )
    }

    private func stepButton(_ step: WizardModel.Step) -> some View {
        let isCurrent = step == model.step
        let isReachable = model.canJump(to: step)
        let isPassed = step.rawValue < model.step.rawValue

        return Button {
            model.jump(to: step)
        } label: {
            HStack(spacing: 7) {
                Text("\(step.rawValue + 1)")
                    .font(RouterTheme.mono(10.5, .medium))
                    .foregroundStyle(isCurrent ? RouterTheme.accent : (isPassed ? RouterTheme.ink : RouterTheme.ink3))
                    .frame(width: 18, height: 18)
                    .background(
                        isCurrent
                            ? RouterTheme.accent.opacity(0.12)
                            : (isPassed ? Color.white.opacity(0.04) : Color.clear),
                        in: Circle()
                    )
                    .overlay(
                        Circle().strokeBorder(
                            isCurrent
                                ? RouterTheme.accent.opacity(0.5)
                                : (isPassed ? RouterTheme.line2 : RouterTheme.line),
                            lineWidth: 1
                        )
                    )
                Text(step.title)
                    .font(RouterTheme.sans(12, isCurrent ? .medium : .regular))
                    .foregroundStyle(isCurrent ? RouterTheme.ink : (isPassed ? RouterTheme.ink2 : RouterTheme.ink3))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isReachable)
    }
}

/// Shared heading used by each step.
struct StepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
