import Foundation
import Testing
@testable import SwitchyardDesktopKit

#if DEBUG
@MainActor
@Test func xcodeRunUsesTheAppsOwnPortsWithoutRelyingOnTheManualExperiment() {
    let model = WizardModel(restoreSavedSetup: false)

    #expect(model.profile.upstreamBaseURL == LiteLLMProcessManager.upstream)
    #expect(model.profile.port == 4100)
    #expect(model.profile.usesManagedLiteLLM)
}
#endif

private let sampleSetup = CodexSetup(
    configPath: URL(fileURLWithPath: "/tmp/switchyard-desktop-codex/config.toml"),
    model: "gpt-5.6-sol",
    modelProvider: "openai"
)

private let twoDiscoveredModels = [
    CodexSubscriptionModel(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra", isDefault: false),
    CodexSubscriptionModel(id: "gpt-6-astra", displayName: "GPT-6 Astra", isDefault: true),
]

private let oneDiscoveredModel = [
    CodexSubscriptionModel(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra", isDefault: false),
]

private enum SetupStubOutput: Sendable {
    case setup(CodexSetup)
    case failure(CodexSetupReader.Failure)
}

private struct StubSetupReader: CodexSetupReading {
    let output: SetupStubOutput

    func read(configPath: URL) throws -> CodexSetup {
        switch output {
        case .setup(let setup):
            return setup
        case .failure(let failure):
            throw failure
        }
    }
}

private enum DiscoveryStubOutput: Sendable {
    case models([CodexSubscriptionModel])
    case failure(CodexModelDiscovery.Failure)
}

private struct StubModelDiscovery: CodexModelDiscovering {
    let output: DiscoveryStubOutput

    func discover(using _: CodexSetup) throws -> [CodexSubscriptionModel] {
        switch output {
        case .models(let models):
            return models
        case .failure(let failure):
            throw failure
        }
    }
}

private final class SequencedModelDiscovery: @unchecked Sendable, CodexModelDiscovering {
    private let lock = NSLock()
    private var outputs: [DiscoveryStubOutput]

    init(outputs: [DiscoveryStubOutput]) {
        self.outputs = outputs
    }

    func discover(using _: CodexSetup) throws -> [CodexSubscriptionModel] {
        lock.lock()
        defer { lock.unlock() }
        let output = outputs.removeFirst()
        switch output {
        case .models(let models):
            return models
        case .failure(let failure):
            throw failure
        }
    }
}

@MainActor
private func modelReadyForTiers() -> WizardModel {
    WizardModel(
        codexConfigPath: sampleSetup.configPath,
        setupReader: StubSetupReader(output: .setup(sampleSetup)),
        modelDiscovery: StubModelDiscovery(output: .models(twoDiscoveredModels))
    )
}

@MainActor
private func modelReadyForDiscovery(
    setupResult: SetupStubOutput = .setup(sampleSetup),
    discoveryResult: DiscoveryStubOutput = .models(twoDiscoveredModels),
    discoveryPath: URL = sampleSetup.configPath
) -> WizardModel {
    let model = WizardModel(
        codexConfigPath: discoveryPath,
        setupReader: StubSetupReader(output: setupResult),
        modelDiscovery: StubModelDiscovery(output: discoveryResult)
    )
    return model
}

@MainActor
private func modelReadyForTiersAfterDiscovery() async -> WizardModel {
    let model = modelReadyForTiers()
    model.selectRoutingAlgorithm(.stageRouter)
    model.step = .tiers
    await model.refreshSubscriptionModels()
    return model
}

/// Assigns a distinct model to every tier so the profile becomes complete.
@MainActor
private func assignAllTiers(_ model: WizardModel) {
    for index in model.profile.tiers.indices {
        model.profile.tiers[index].modelID = "model-\(index)"
    }
}

@MainActor
@Test func theWizardStartsOnTheProviderStep() {
    let model = modelReadyForDiscovery()
    #expect(model.step == .provider)
    #expect(!model.canGoBack)
    #expect(!model.canAdvance)
    #expect(model.advanceBlocker == "Check your Codex setup before continuing.")
}

@MainActor
@Test func discoveryFailureBlocksTheWizard() async {
    let model = modelReadyForDiscovery(
        setupResult: .setup(sampleSetup),
        discoveryResult: .failure(CodexModelDiscovery.Failure.unauthenticated)
    )
    await model.discoverSubscriptionModelsIfNeeded()

    #expect(!model.canAdvance)
    #expect(model.discoveryState == .discoveryFailed(.unauthenticated))
    #expect(!model.discoveryState.isReady)
}

@MainActor
@Test func missingAndMalformedCodexConfigurationBlockTheWizard() async {
    let missing = modelReadyForDiscovery(
        setupResult: .failure(CodexSetupReader.Failure.missingConfiguration)
    )
    await missing.discoverSubscriptionModelsIfNeeded()
    #expect(missing.discoveryState == .setupFailed(.missingConfiguration))
    #expect(!missing.canAdvance)

    let malformed = modelReadyForDiscovery(
        setupResult: .failure(CodexSetupReader.Failure.malformedConfiguration)
    )
    await malformed.discoverSubscriptionModelsIfNeeded()
    #expect(malformed.discoveryState == .setupFailed(.malformedConfiguration))
    #expect(!malformed.canAdvance)
}

@MainActor
@Test func emptyAndUnavailableDiscoveryBlockTheWizard() async {
    let empty = modelReadyForDiscovery(
        discoveryResult: .failure(CodexModelDiscovery.Failure.noModels)
    )
    await empty.discoverSubscriptionModelsIfNeeded()
    #expect(empty.discoveryState == .discoveryFailed(.noModels))
    #expect(!empty.canAdvance)

    let unavailable = modelReadyForDiscovery(
        discoveryResult: .failure(CodexModelDiscovery.Failure.appServerUnavailable)
    )
    await unavailable.discoverSubscriptionModelsIfNeeded()
    #expect(unavailable.discoveryState == .discoveryFailed(.appServerUnavailable))
    #expect(!unavailable.canAdvance)
}

@MainActor
@Test func refreshReplacesTheSubscriptionModelList() async {
    let refreshedModels = [
        CodexSubscriptionModel(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", isDefault: true),
        oneDiscoveredModel[0],
    ]
    let model = WizardModel(
        codexConfigPath: sampleSetup.configPath,
        setupReader: StubSetupReader(output: .setup(sampleSetup)),
        modelDiscovery: SequencedModelDiscovery(outputs: [
            .models(twoDiscoveredModels),
            .models(refreshedModels),
        ])
    )

    await model.discoverSubscriptionModelsIfNeeded()
    model.selectRoutingAlgorithm(.stageRouter)
    model.profile.tiers[0].modelID = "gpt-6-astra"
    await model.refreshSubscriptionModels()

    #expect(model.discoveredModels == refreshedModels)
    #expect(model.profile.tiers[0].assignedModel == nil)
}

@MainActor
@Test func theAccountStepNeedsAtLeastTwoDiscoveredModels() async {
    let model = modelReadyForDiscovery(discoveryResult: .models(oneDiscoveredModel))
    model.step = .provider
    await model.refreshSubscriptionModels()
    #expect(!model.canAdvance)
    #expect(model.advanceBlocker?.contains("at least two models") == true)

    let multiModel = WizardModel(
        codexConfigPath: sampleSetup.configPath,
        setupReader: StubSetupReader(output: .setup(sampleSetup)),
        modelDiscovery: StubModelDiscovery(output: .models(twoDiscoveredModels))
    )
    multiModel.step = .provider
    await multiModel.refreshSubscriptionModels()
    #expect(multiModel.canAdvance)
    // The merged step goes straight to the roles it just enabled.
    multiModel.next()
    #expect(multiModel.step == .tiers)
}

@MainActor
@Test func theTierStepBlocksUntilEveryTierIsAssigned() async {
    let model = await modelReadyForTiersAfterDiscovery()
    #expect(model.profile.tiers.count == 2)
    #expect(!model.canAdvance)
    // The blocker names every tier still missing a model.
    #expect(model.advanceBlocker?.contains("Efficient") == true)
    #expect(model.advanceBlocker?.contains("Capable") == true)

    model.profile.tiers[0].modelID = "gpt-5.6-terra"
    #expect(!model.canAdvance)
    #expect(model.advanceBlocker?.contains("Efficient") == false)
    #expect(model.advanceBlocker?.contains("Capable") == true)

    model.profile.tiers[1].modelID = "gpt-6-astra"
    #expect(model.canAdvance)
    #expect(model.advanceBlocker == nil)

    model.next()
    #expect(model.step == .confirm)
}

@MainActor
@Test func tiersCanBeAddedAndRemovedWithinTheSupportedRange() {
    let model = modelReadyForTiers()
    model.selectRoutingAlgorithm(.llmClassifier)

    model.addTier()
    #expect(model.profile.tiers.count == 3)

    model.removeTier(id: model.profile.tiers[1].id)
    #expect(model.profile.tiers.count == 2)

    while model.canRemoveTier { model.removeTier(id: model.profile.tiers[0].id) }
    #expect(model.profile.tiers.count == TaskTier.minimumCount)
    #expect(!model.canRemoveTier)

    while model.canAddTier { model.addTier() }
    #expect(model.profile.tiers.count == TaskTier.maximumCount)
    #expect(!model.canAddTier)
}

@MainActor
@Test func theRoutingSummaryReflectsTheSelectedAlgorithm() {
    let model = modelReadyForTiers()
    #expect(model.routingSummary.contains("Choose a routing algorithm"))

    model.selectRoutingAlgorithm(.stageRouter)
    #expect(model.routingSummary.contains("every request"))

    model.selectRoutingAlgorithm(.llmClassifier)
    #expect(model.routingSummary.contains("every request, including tool continuations"))
}

@MainActor
@Test func removingAnAssignedModelClearsItsTier() async {
    let model = modelReadyForDiscovery(
        discoveryResult: .models([oneDiscoveredModel[0]])
    )
    model.selectRoutingAlgorithm(.llmClassifier)
    model.addTier()
    model.profile.tiers[0].modelID = oneDiscoveredModel[0].id
    model.profile.tiers[1].modelID = "gone-model"
    model.profile.tiers[2].modelID = oneDiscoveredModel[0].id

    await model.refreshSubscriptionModels()

    #expect(model.profile.tiers[1].assignedModel == nil)
    #expect(model.profile.tiers[0].assignedModel == oneDiscoveredModel[0].id)
}

@MainActor
@Test func modelAssignmentsToUnknownIDsAreBlocked() async {
    let model = await modelReadyForTiersAfterDiscovery()
    model.profile.tiers[0].modelID = "not-in-discovery"
    #expect(model.advanceBlocker?.contains("Choose a discovered Codex model") == true)
    #expect(!model.canAdvance)
}

@MainActor
@Test func navigationCannotStepPastTheEnds() {
    let model = modelReadyForDiscovery()
    model.back()
    #expect(model.step == .provider)

    model.step = .confirm
    model.next()
    #expect(model.step == .confirm)
}

@MainActor
@Test func theConfigPreviewIsEmptyUntilTheProfileIsComplete() async {
    let model = await modelReadyForTiersAfterDiscovery()
    #expect(model.configPreview.isEmpty)

    assignAllTiers(model)

    // All assignments are still unknown to discovery and should stay blocked.
    #expect(model.configPreview.isEmpty)

    model.profile.tiers[0].modelID = oneDiscoveredModel[0].id
    model.profile.tiers[1].modelID = twoDiscoveredModels[0].id
    #expect(model.configPreview.contains("stage_router"))

    model.selectRoutingAlgorithm(.llmClassifier)
    // Two distinct models: targets now hold different roles, and Switchyard
    // keeps one target per model, so sharing one would be a different failure.
    model.profile.tiers[0].modelID = twoDiscoveredModels[0].id
    model.profile.tiers[1].modelID = twoDiscoveredModels[1].id
    model.profile.classifierTargetID = model.profile.tiers[0].id
    model.profile.defaultTargetID = model.profile.tiers[1].id
    // Targets arrive on roles, so they are described from the start.
    #expect(model.configPreview.contains("llm_classifier"))

    // The judge reads those descriptions and nothing else, so a target taken
    // off its role and left blank blocks the preview again.
    for tier in model.profile.tiers { model.assignRole(nil, to: tier.id) }
    for index in model.profile.tiers.indices { model.profile.tiers[index].summary = "" }
    #expect(model.configPreview.isEmpty)

    for index in model.profile.tiers.indices {
        model.profile.tiers[index].summary = "Work for target \(index + 1)."
    }
    #expect(model.configPreview.contains("llm_classifier"))
}

@MainActor
@Test func applyWithoutABinaryReportsInstallInstructions() async {
    let model = WizardModel(
        codexConfigPath: sampleSetup.configPath,
        setupReader: StubSetupReader(output: .setup(sampleSetup)),
        modelDiscovery: StubModelDiscovery(output: .models(twoDiscoveredModels))
    )
    model.selectRoutingAlgorithm(.stageRouter)
    assignAllTiers(model)
    model.profile.tiers[0].modelID = oneDiscoveredModel[0].id
    model.profile.tiers[1].modelID = twoDiscoveredModels[0].id
    await model.refreshSubscriptionModels()
    // Force resolution to fail regardless of what this machine has installed.
    model.binaryPathOverride = "/nonexistent/switchyard-server"

    guard model.resolvedBinary == nil else { return }  // dev machine has a real binary on PATH

    await model.apply()
    guard case .failed(let message) = model.applyState else {
        Issue.record("expected apply to fail without a binary")
        return
    }
    #expect(message.contains("cargo install"))
}

/// A stand-in server that ignores its arguments and stays alive, so the model
/// sees a running proxy without this test starting a real one.
@MainActor
private func startStubProxy(_ manager: SwitchyardProcessManager) async throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("stub-server.sh")
    try "#!/bin/sh\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

    let config = directory.appendingPathComponent("routes.toml")
    try "schema_version = 1\n".write(to: config, atomically: true, encoding: .utf8)
    try await manager.start(configPath: config, binaryPath: script, port: 4188)
    return directory
}

@MainActor
@Test func refreshIsBlockedWhileCodexIsRoutedThroughThisApp() async throws {
    let manager = SwitchyardProcessManager()
    let model = WizardModel(
        processManager: manager,
        codexConfigPath: sampleSetup.configPath,
        setupReader: StubSetupReader(output: .setup(sampleSetup)),
        modelDiscovery: SequencedModelDiscovery(outputs: [
            .models(twoDiscoveredModels),
            .models(oneDiscoveredModel),
        ])
    )
    await model.refreshSubscriptionModels()
    #expect(model.canRefreshDiscovery)

    let directory = try await startStubProxy(manager)
    defer {
        manager.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    // Codex now reports this app's own route as its only model, so a refresh
    // would collapse the list and clear every assignment.
    #expect(!model.canRefreshDiscovery)
    #expect(model.discoveryRefreshBlocker != nil)

    await model.refreshSubscriptionModels()

    #expect(model.discoveredModels == twoDiscoveredModels)
}

// MARK: - Context window discovery

private struct WindowedDiscovery: CodexModelDiscovering {
    var models: [CodexSubscriptionModel]
    var windows: [String: Int]

    func discover(using _: CodexSetup) throws -> [CodexSubscriptionModel] { models }
    func contextWindows(using _: CodexSetup) -> [String: Int] { windows }
}

@MainActor
private func modelReadyForWindows(_ windows: [String: Int]) -> WizardModel {
    WizardModel(
        codexConfigPath: sampleSetup.configPath,
        setupReader: StubSetupReader(output: .setup(sampleSetup)),
        modelDiscovery: WindowedDiscovery(models: twoDiscoveredModels, windows: windows)
    )
}

@MainActor
@Test func discoveryRecordsEveryModelsLargestWindow() async {
    let model = modelReadyForWindows(["gpt-5.6-terra": 872_000, "gpt-6-astra": 872_000])

    await model.refreshSubscriptionModels()

    #expect(model.profile.modelContextWindows == ["gpt-5.6-terra": 872_000, "gpt-6-astra": 872_000])
}

/// A setup saved before windows were ever discovered would otherwise put Codex
/// back on its own default the moment it is restored.
@MainActor
@Test func aProfileTakingOverKeepsTheDiscoveredWindows() async {
    let model = modelReadyForWindows(["gpt-6-astra": 872_000])
    await model.refreshSubscriptionModels()

    model.profile = RoutingProfile(provider: .codex, algorithm: .passthrough)

    #expect(model.profile.modelContextWindows == ["gpt-6-astra": 872_000])
}

/// An unreadable catalog is a reason to leave the route as it is, not to shrink
/// it back to Codex's default.
@MainActor
@Test func aFailedWindowReadKeepsTheWindowsAlreadyKnown() async {
    let discovery = FadingWindowDiscovery(models: twoDiscoveredModels, windows: ["gpt-6-astra": 872_000])
    let model = WizardModel(
        codexConfigPath: sampleSetup.configPath,
        setupReader: StubSetupReader(output: .setup(sampleSetup)),
        modelDiscovery: discovery
    )
    await model.refreshSubscriptionModels()

    // The catalog is unreadable this time round.
    await model.refreshSubscriptionModels()

    #expect(model.profile.modelContextWindows == ["gpt-6-astra": 872_000])
}

/// Answers windows once, then nothing — a Codex that stopped rendering its
/// catalog while the model list still works.
private final class FadingWindowDiscovery: CodexModelDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private let models: [CodexSubscriptionModel]
    private var remaining: [String: Int]

    init(models: [CodexSubscriptionModel], windows: [String: Int]) {
        self.models = models
        self.remaining = windows
    }

    func discover(using _: CodexSetup) throws -> [CodexSubscriptionModel] { models }

    func contextWindows(using _: CodexSetup) -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        let answer = remaining
        remaining = [:]
        return answer
    }
}

// MARK: - Long context setting

private final class MemoryPreferencesStore: AppPreferencesStoring, @unchecked Sendable {
    var stored: AppPreferences?
    func load() throws -> AppPreferences? { stored }
    func save(_ preferences: AppPreferences) throws { stored = preferences }
}

@MainActor
private func modelReadyForWindows(
    _ windows: [String: Int], preferences: MemoryPreferencesStore
) -> WizardModel {
    WizardModel(
        codexConfigPath: sampleSetup.configPath,
        preferencesStore: preferences,
        setupReader: StubSetupReader(output: .setup(sampleSetup)),
        modelDiscovery: WindowedDiscovery(models: twoDiscoveredModels, windows: windows)
    )
}

@MainActor
@Test func longContextIsAllowedUntilTheUserTurnsItOff() {
    let model = modelReadyForWindows([:], preferences: MemoryPreferencesStore())

    #expect(model.allowsLongContext)
    #expect(model.profile.allowsLongContext)
}

@MainActor
@Test func turningLongContextOffReachesTheProfileAndIsSaved() {
    let store = MemoryPreferencesStore()
    let model = modelReadyForWindows([:], preferences: store)

    model.allowsLongContext = false

    #expect(!model.profile.allowsLongContext)
    #expect(store.stored == AppPreferences(allowsLongContext: false))
}

@MainActor
@Test func aSavedLongContextChoiceIsRestoredAtLaunch() {
    let store = MemoryPreferencesStore()
    store.stored = AppPreferences(allowsLongContext: false)

    let model = modelReadyForWindows([:], preferences: store)

    #expect(!model.allowsLongContext)
    #expect(!model.profile.allowsLongContext)
}

/// A preset or saved setup is a setup, not the user's spending choice.
@MainActor
@Test func aProfileTakingOverKeepsTheLongContextChoice() {
    let model = modelReadyForWindows([:], preferences: MemoryPreferencesStore())
    model.allowsLongContext = false

    model.profile = RoutingProfile(provider: .codex, algorithm: .passthrough, allowsLongContext: true)

    #expect(!model.profile.allowsLongContext)
}

@MainActor
@Test func longContextOffHoldsTheDiscoveredRouteAtTheStandardWindow() async {
    let model = modelReadyForWindows(
        ["gpt-5.6-terra": 872_000, "gpt-6-astra": 872_000], preferences: MemoryPreferencesStore()
    )
    await model.refreshSubscriptionModels()
    model.selectRoutingAlgorithm(.stageRouter)
    model.profile.tiers[0].modelID = "gpt-5.6-terra"
    model.profile.tiers[1].modelID = "gpt-6-astra"
    #expect(model.profile.routeContextWindow == 872_000)

    model.allowsLongContext = false

    #expect(model.profile.routeContextWindow == 272_000)
}
