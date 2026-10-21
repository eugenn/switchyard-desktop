import Foundation
import Testing
@testable import SwitchyardDesktopKit

private let preflightSetup = CodexSetup(
    configPath: URL(fileURLWithPath: "/tmp/codex/config.toml"),
    model: "gpt-6-astra",
    modelProvider: "openai"
)

private let preflightModels = [
    CodexSubscriptionModel(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra", isDefault: false),
    CodexSubscriptionModel(id: "gpt-6-astra", displayName: "GPT-6 Astra", isDefault: true),
]

private func makePreflight(
    state: WizardModel.DiscoveryState,
    setup: CodexSetup? = preflightSetup,
    cliVersion: String? = "v0.48.1"
) -> CodexPreflight {
    CodexPreflight.make(
        state: state,
        setup: setup,
        cliVersion: cliVersion,
        modelCount: state.models.count,
        defaultModelID: state.models.first(where: \.isDefault)?.id
    )
}

@Test func readyPreflightPassesEveryStageAndShowsTheConfiguredValues() {
    let preflight = makePreflight(state: .ready(preflightModels))

    #expect(preflight.checks.allSatisfy { $0.outcome == .passed })
    #expect(preflight.check(.configuration).detail.contains("model_provider = openai"))
    #expect(preflight.check(.configuration).detail.contains("model = gpt-6-astra"))
    #expect(preflight.check(.cli).value == "v0.48.1")
    #expect(preflight.check(.models).value == "2 found")
    #expect(preflight.check(.models).detail.contains("gpt-6-astra"))
    #expect(preflight.summary == "2 subscription models found.")
    #expect(preflight.summaryOutcome == .passed)
    #expect(preflight.actionTitle == "Refresh models")
    #expect(preflight.fix == nil)
}

@Test func missingConfigurationStopsAtTheFirstStage() {
    let preflight = makePreflight(state: .setupFailed(.missingConfiguration), setup: nil, cliVersion: nil)

    #expect(preflight.check(.configuration).outcome == .failed)
    #expect(preflight.check(.configuration).value == "not found")
    for stage in [CodexPreflight.Stage.cli, .signIn, .models] {
        #expect(preflight.check(stage).outcome == .notChecked)
        #expect(preflight.check(stage).detail == CodexPreflight.notChecked)
    }
    #expect(preflight.fix?.title == "Configure Codex first")
    #expect(preflight.summaryOutcome == .failed)
}

@Test func signedOutPreflightPassesTheEarlierStagesAndFailsOnlySignIn() {
    let preflight = makePreflight(state: .discoveryFailed(.unauthenticated))

    #expect(preflight.check(.configuration).outcome == .passed)
    #expect(preflight.check(.cli).outcome == .passed)
    #expect(preflight.check(.signIn).outcome == .failed)
    #expect(preflight.check(.signIn).value == "signed out")
    #expect(preflight.check(.models).outcome == .notChecked)
    #expect(preflight.fix?.title == "Sign in to Codex")
    #expect(preflight.actionTitle == "Try again")
}

@Test func missingCodexCLIFailsOnTheCLIStage() {
    let preflight = makePreflight(state: .discoveryFailed(.codexUnavailable), cliVersion: nil)

    #expect(preflight.check(.cli).outcome == .failed)
    #expect(preflight.check(.cli).value == "not found")
    #expect(preflight.check(.signIn).outcome == .notChecked)
    #expect(preflight.fix?.title == "Install the Codex CLI")
}

@Test func emptyModelListFailsOnlyTheModelStage() {
    let preflight = makePreflight(state: .discoveryFailed(.noModels))

    #expect(preflight.check(.signIn).outcome == .passed)
    #expect(preflight.check(.models).outcome == .failed)
    #expect(preflight.check(.models).value == "none")
}

@Test func loadingPreflightReportsWorkAndDisablesItsAction() {
    let preflight = makePreflight(state: .loading, setup: nil, cliVersion: nil)

    #expect(preflight.check(.configuration).outcome == .working)
    #expect(preflight.summaryOutcome == .working)
    #expect(preflight.actionEnabled == false)
}

@Test func configurationDetailExplainsCodexDefaultsWhenNoValuesAreSet() {
    let bare = CodexSetup(
        configPath: URL(fileURLWithPath: "/tmp/codex/config.toml"),
        model: nil,
        modelProvider: nil
    )
    let preflight = makePreflight(state: .ready(preflightModels), setup: bare)

    #expect(preflight.check(.configuration).detail.contains("built-in defaults"))
}
