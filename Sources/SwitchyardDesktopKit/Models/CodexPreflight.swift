import Foundation

/// The four setup checks shown on step 1, derived from one discovery attempt.
///
/// Discovery itself is a single sequence (read the config, run `codex
/// app-server`, authenticate, list models), so this type splits its one outcome
/// into the per-stage rows the step displays, and marks the stages that never
/// ran as not checked rather than as passing.
package struct CodexPreflight: Equatable, Sendable {
    package enum Outcome: Equatable, Sendable {
        case passed
        case failed
        case working
        case notChecked
    }

    package enum Stage: String, Equatable, Sendable, Identifiable, CaseIterable {
        case configuration
        case cli
        case signIn
        case models

        package var id: String { rawValue }

        package var title: String {
            switch self {
            case .configuration: "Codex configuration"
            case .cli: "Codex CLI"
            case .signIn: "Codex sign-in"
            case .models: "Subscription models"
            }
        }
    }

    package struct Check: Equatable, Sendable, Identifiable {
        package let stage: Stage
        package let outcome: Outcome
        package let detail: String
        package let value: String

        package var id: String { stage.rawValue }
        package var title: String { stage.title }
    }

    package struct Fix: Equatable, Sendable {
        package let title: String
        package let message: String
    }

    /// Blocking stages are not checked until the preceding one passes.
    package static let notChecked = "Not checked — the earlier step has to pass first."

    package let checks: [Check]
    package let fix: Fix?
    package let summary: String
    package let summaryOutcome: Outcome
    /// Label for the step's own action button.
    package let actionTitle: String
    package let actionEnabled: Bool

    package func check(_ stage: Stage) -> Check {
        checks.first { $0.stage == stage } ?? Check(
            stage: stage, outcome: .notChecked, detail: Self.notChecked, value: "—"
        )
    }

    // MARK: - Derivation

    package static func make(
        state: WizardModel.DiscoveryState,
        setup: CodexSetup?,
        cliVersion: String?,
        modelCount: Int,
        defaultModelID: String?
    ) -> CodexPreflight {
        switch state {
        case .idle, .loading:
            return CodexPreflight(
                checks: [
                    Check(
                        stage: .configuration,
                        outcome: .working,
                        detail: "Reading the local Codex configuration.",
                        value: "reading…"
                    ),
                    pending(.cli), pending(.signIn), pending(.models),
                ],
                fix: nil,
                summary: "Checking the configured Codex subscription…",
                summaryOutcome: .working,
                actionTitle: "Checking Codex…",
                actionEnabled: false
            )

        case .ready:
            return CodexPreflight(
                checks: [
                    Check(
                        stage: .configuration,
                        outcome: .passed,
                        detail: configurationDetail(setup),
                        value: "read"
                    ),
                    Check(
                        stage: .cli,
                        outcome: .passed,
                        detail: "Asks Codex for the model list your subscription can use.",
                        value: cliVersion ?? "available"
                    ),
                    Check(
                        stage: .signIn,
                        outcome: .passed,
                        detail: "Requests go out through Codex's own authenticated session.",
                        value: "active"
                    ),
                    Check(
                        stage: .models,
                        outcome: .passed,
                        detail: defaultModelID.map { "\($0) is the model Codex uses today." }
                            ?? "Codex reported the models your subscription can use.",
                        value: "\(modelCount) found"
                    ),
                ],
                fix: nil,
                summary: "\(modelCount) subscription model\(modelCount == 1 ? "" : "s") found.",
                summaryOutcome: .passed,
                actionTitle: "Refresh models",
                actionEnabled: true
            )

        case .setupFailed(let failure):
            return CodexPreflight(
                checks: [
                    Check(
                        stage: .configuration,
                        outcome: .failed,
                        detail: failure.errorDescription ?? state.blockingMessage,
                        value: configurationFailureValue(failure)
                    ),
                    pending(.cli), pending(.signIn), pending(.models),
                ],
                fix: fix(for: failure),
                summary: failure.errorDescription ?? state.blockingMessage,
                summaryOutcome: .failed,
                actionTitle: "Try again",
                actionEnabled: true
            )

        case .discoveryFailed(let failure):
            return discoveryFailure(failure, setup: setup, cliVersion: cliVersion)

        case .unexpectedFailure:
            return CodexPreflight(
                checks: [
                    Check(
                        stage: .configuration,
                        outcome: .failed,
                        detail: state.blockingMessage,
                        value: "failed"
                    ),
                    pending(.cli), pending(.signIn), pending(.models),
                ],
                fix: Fix(
                    title: "Check your Codex installation",
                    message: """
                        switchyard-desktop could not complete its setup check. Open Codex once to \
                        confirm it runs, then try again.
                        """
                ),
                summary: state.blockingMessage,
                summaryOutcome: .failed,
                actionTitle: "Try again",
                actionEnabled: true
            )
        }
    }

    private static func discoveryFailure(
        _ failure: CodexModelDiscovery.Failure,
        setup: CodexSetup?,
        cliVersion: String?
    ) -> CodexPreflight {
        let configuration = Check(
            stage: .configuration,
            outcome: .passed,
            detail: configurationDetail(setup),
            value: "read"
        )
        let cliPassed = Check(
            stage: .cli,
            outcome: .passed,
            detail: "Asks Codex for the model list your subscription can use.",
            value: cliVersion ?? "available"
        )
        let message = failure.errorDescription ?? "Model discovery failed. Try again."

        switch failure {
        case .codexUnavailable:
            return CodexPreflight(
                checks: [
                    configuration,
                    Check(stage: .cli, outcome: .failed, detail: message, value: "not found"),
                    pending(.signIn), pending(.models),
                ],
                fix: Fix(
                    title: "Install the Codex CLI",
                    message: """
                        switchyard-desktop asks the Codex CLI which models your subscription can use. \
                        Install it so `codex` is on your PATH, then try again.
                        """
                ),
                summary: message,
                summaryOutcome: .failed,
                actionTitle: "Try again",
                actionEnabled: true
            )

        case .unauthenticated:
            return CodexPreflight(
                checks: [
                    configuration, cliPassed,
                    Check(stage: .signIn, outcome: .failed, detail: message, value: "signed out"),
                    pending(.models),
                ],
                fix: Fix(
                    title: "Sign in to Codex",
                    message: """
                        Run `codex login` in Terminal, or open Codex and sign in there. Model \
                        Router uses that session directly and never stores your credentials.
                        """
                ),
                summary: message,
                summaryOutcome: .failed,
                actionTitle: "Try again",
                actionEnabled: true
            )

        case .noModels, .invalidResponse, .incompleteResult, .appServerUnavailable:
            let value: String = switch failure {
            case .noModels: "none"
            case .invalidResponse: "unexpected"
            case .incompleteResult: "too many"
            default: "unavailable"
            }
            return CodexPreflight(
                checks: [
                    configuration, cliPassed,
                    Check(
                        stage: .signIn,
                        outcome: .passed,
                        detail: "Requests go out through Codex's own authenticated session.",
                        value: "active"
                    ),
                    Check(stage: .models, outcome: .failed, detail: message, value: value),
                ],
                fix: Fix(title: "Codex reported no usable models", message: message),
                summary: message,
                summaryOutcome: .failed,
                actionTitle: "Try again",
                actionEnabled: true
            )
        }
    }

    private static func pending(_ stage: Stage) -> Check {
        Check(stage: stage, outcome: .notChecked, detail: notChecked, value: "—")
    }

    private static func configurationDetail(_ setup: CodexSetup?) -> String {
        guard let setup else { return "Read from the local Codex configuration." }
        let values = [
            setup.modelProvider.map { "model_provider = \($0)" },
            setup.model.map { "model = \($0)" },
        ].compactMap { $0 }
        return values.isEmpty
            ? "Codex uses its built-in defaults for provider and model."
            : values.joined(separator: " · ")
    }

    private static func configurationFailureValue(_ failure: CodexSetupReader.Failure) -> String {
        switch failure {
        case .missingConfiguration: "not found"
        case .unreadableConfiguration: "unreadable"
        case .malformedConfiguration: "malformed"
        case .invalidFieldType, .emptyField: "invalid"
        }
    }

    private static func fix(for failure: CodexSetupReader.Failure) -> Fix {
        switch failure {
        case .missingConfiguration:
            Fix(
                title: "Configure Codex first",
                message: """
                    Install Codex and run it once so it writes `~/.codex/config.toml`. Model \
                    Router reads that file — it does not create or change it during setup.
                    """
            )
        case .unreadableConfiguration:
            Fix(
                title: "Let switchyard-desktop read the Codex configuration",
                message: """
                    `~/.codex/config.toml` exists but cannot be read. Check its file \
                    permissions, then try again.
                    """
            )
        case .malformedConfiguration:
            Fix(
                title: "Fix the Codex configuration",
                message: """
                    `~/.codex/config.toml` is not valid TOML. Repair it in Codex, then try again.
                    """
            )
        case .invalidFieldType(let field), .emptyField(let field):
            Fix(
                title: "Fix the Codex \(field) setting",
                message: """
                    `~/.codex/config.toml` has an unusable `\(field)` value. Set it in Codex, \
                    then try again.
                    """
            )
        }
    }
}
