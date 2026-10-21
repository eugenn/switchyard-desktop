import Foundation
import Testing
@testable import SwitchyardDesktopKit

private func reusableSetup() -> SavedRoutingSetup {
    let models = [
        CodexSubscriptionModel(id: "gpt-fast", displayName: "Fast", isDefault: true),
        CodexSubscriptionModel(id: "gpt-strong", displayName: "Strong", isDefault: false),
    ]
    let profile = RoutingProfile(
        provider: .codex,
        algorithm: .stageRouter,
        tiers: [
            TaskTier(name: "Efficient", summary: "Small work.", modelID: models[0].id),
            TaskTier(name: "Capable", summary: "Hard work.", modelID: models[1].id),
        ],
        upstreamBaseURL: LiteLLMProcessManager.developmentUpstream
    )
    return SavedRoutingSetup(
        profile: profile,
        discoveredModels: models,
        binaryPathOverride: "/tmp/switchyard-server",
        savedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private final class MemorySavedSetupStore: SavedRoutingSetupStoring {
    var setup: SavedRoutingSetup?
    private(set) var saveCount = 0

    init(_ setup: SavedRoutingSetup? = nil) {
        self.setup = setup
    }

    func load() throws -> SavedRoutingSetup? { setup }
    func save(_ setup: SavedRoutingSetup) throws {
        self.setup = setup
        saveCount += 1
    }
    func clear() throws { setup = nil }
}

private struct SavedSetupReader: CodexSetupReading {
    func read(configPath: URL) throws -> CodexSetup {
        CodexSetup(configPath: configPath, model: "gpt-fast", modelProvider: "openai")
    }
}

private struct SavedSetupDiscovery: CodexModelDiscovering {
    let models: [CodexSubscriptionModel]

    init(_ models: [CodexSubscriptionModel]) {
        self.models = models
    }

    func discover(using _: CodexSetup) throws -> [CodexSubscriptionModel] { models }
}

private final class MemoryActiveSessionStore: ActiveRoutingSessionStoring {
    var session: ActiveRoutingSession?

    func load() throws -> ActiveRoutingSession? { session }
    func save(_ session: ActiveRoutingSession) throws { self.session = session }
    func clear() throws { session = nil }
}

private struct SavedSetupReadyChecker: RoutingReadinessChecking {
    let binary: URL

    func check(
        profile: RoutingProfile,
        binaryPathOverride: String,
        routingConfigPath: URL,
        codexProfilePath: URL
    ) -> RoutingReadiness {
        RoutingReadiness(
            routingConfigPath: routingConfigPath,
            codexProfilePath: codexProfilePath,
            resolvedBinaryPath: binary,
            serverSupportsVision: false,
            binary: .passed("Ready."),
            generatedConfig: .passed("Ready."),
            dryRun: .passed("Ready."),
            codexProfile: .passed("Ready."),
            endpoint: .passed("Ready."),
            upstream: .passed("Ready.")
        )
    }
}

@Test func savedRoutingSetupRoundTripsOnDisk() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SavedRoutingSetupStore(fileURL: directory.appendingPathComponent("setup.json"))
    let setup = reusableSetup()

    try store.save(setup)

    #expect(try store.load() == setup)
    try store.clear()
    #expect(try store.load() == nil)
}

@MainActor
@Test func savedRoutingSetupSkipsTheFirstRunWizard() async {
    let setup = reusableSetup()
    let store = MemorySavedSetupStore(setup)
    let model = WizardModel(
        savedSetupStore: store,
        setupReader: SavedSetupReader(),
        modelDiscovery: SavedSetupDiscovery(setup.discoveredModels),
        restoreSavedSetup: true
    )

    #expect(model.step == .confirm)
    #expect(model.profile == setup.profile)
    #expect(model.binaryPathOverride == setup.binaryPathOverride)
    #expect(model.hasSavedSetup)
    #expect(model.lastSavedSetup == setup)
    // The saved snapshot is never passed off as a completed discovery.
    #expect(!model.discoveryState.isReady)

    await model.discoverSubscriptionModelsIfNeeded()
    #expect(model.discoveredModels == setup.discoveredModels)
    #expect(model.profile == setup.profile)

    model.reconfigure()
    #expect(model.step == .provider)
}

@MainActor
@Test func restoringASetupDropsAnAssignmentTheSubscriptionNoLongerOffers() async {
    let setup = reusableSetup()
    let store = MemorySavedSetupStore(setup)
    let remaining = Array(setup.discoveredModels.dropFirst())
    let model = WizardModel(
        savedSetupStore: store,
        setupReader: SavedSetupReader(),
        modelDiscovery: SavedSetupDiscovery(remaining),
        restoreSavedSetup: true
    )

    await model.discoverSubscriptionModelsIfNeeded()

    #expect(model.discoveredModels == remaining)
    #expect(model.profile.tiers[0].assignedModel == nil)
    #expect(model.unverifiedAssignmentBlocker == nil)
    #expect(model.canApply == false)
}

@MainActor
@Test func invalidSavedRoutingSetupFallsBackToFirstRun() {
    let valid = reusableSetup()
    let invalid = SavedRoutingSetup(
        profile: valid.profile,
        discoveredModels: [valid.discoveredModels[0]],
        binaryPathOverride: "",
        savedAt: valid.savedAt
    )
    let store = MemorySavedSetupStore(invalid)

    let model = WizardModel(savedSetupStore: store)

    #expect(model.step == .provider)
    #expect(!model.hasSavedSetup)
    #expect(model.savedSetupWarning != nil)
    #expect(store.setup == nil)
}

@MainActor
@Test func existingGeneratedRoutesMigrateWithoutRepeatingSetup() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let routes = directory.appendingPathComponent("routes.toml")
    try """
    schema_version = 1

    [llm_clients.openai]
    format = "openai_responses"
    base_url = "http://127.0.0.1:4001/v1"
    forward_auth = false

    [targets.efficient]
    id = "gpt-fast"
    llm_client = "openai"

    [targets.capable]
    id = "gpt-strong"
    llm_client = "openai"

    [routes.main]
    id = "switchyard-desktop"
    type = "stage_router"
    efficient_target = "efficient"
    capable_target = "capable"
    vision = true
    """.write(to: routes, atomically: true, encoding: .utf8)
    let store = MemorySavedSetupStore()

    let model = WizardModel(
        routingConfigPath: routes,
        savedSetupStore: store,
        restoreSavedSetup: true
    )

    #expect(model.step == .confirm)
    #expect(model.profile.algorithm == .stageRouter)
    #expect(model.profile.tiers.compactMap(\.assignedModel) == ["gpt-fast", "gpt-strong"])
    #expect(model.profile.upstreamBaseURL == "http://127.0.0.1:4001/v1")
    #expect(model.profile.advertisesImageInput)
    #expect(store.saveCount == 1)
}

@MainActor
@Test func successfulStartRefreshesTheReusableSetup() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let binary = directory.appendingPathComponent("switchyard-server")
    try """
    #!/bin/sh
    for argument in "$@"; do
      if [ "$argument" = "--dry-run" ]; then exit 0; fi
    done
    exec /bin/sleep 30
    """.write(to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: binary.path
    )
    let codexConfig = directory.appendingPathComponent("config.toml")
    try "model = \"original\"\nmodel_provider = \"openai\"\n"
        .write(to: codexConfig, atomically: true, encoding: .utf8)

    let initial = reusableSetup()
    let setupStore = MemorySavedSetupStore(initial)
    let sessionStore = MemoryActiveSessionStore()
    let manager = SwitchyardProcessManager(startupGracePeriod: .milliseconds(10))
    let model = WizardModel(
        processManager: manager,
        readinessChecker: SavedSetupReadyChecker(binary: binary),
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexConfigPath: codexConfig,
        sessionStore: sessionStore,
        savedSetupStore: setupStore,
        setupReader: SavedSetupReader(),
        modelDiscovery: SavedSetupDiscovery(initial.discoveredModels),
        restoreSavedSetup: true
    )
    await model.discoverSubscriptionModelsIfNeeded()
    model.profile.port = 52_777

    await model.apply()

    #expect(model.isApplied)
    #expect(setupStore.saveCount == 1)
    #expect(setupStore.setup?.profile == model.profile)
    #expect(await model.revert())
}

// MARK: - Migrating a generated configuration

/// The writer and this reader have to agree on the classifier route's shape:
/// an app that generated `routes.toml` before reusable setups existed is
/// restored only by reading that file back.
@Test func migrationRestoresAClassifierSetupFromAGeneratedConfig() throws {
    let tiers = [
        TaskTier(name: "Efficient", summary: "Small work.", modelID: "gpt-fast"),
        TaskTier(name: "Balanced", summary: "Everyday work.", modelID: "gpt-mid"),
        TaskTier(name: "Capable", summary: "Hard work.", modelID: "gpt-strong"),
    ]
    let profile = RoutingProfile(
        provider: .codex,
        algorithm: .llmClassifier,
        tiers: tiers,
        classifierTargetID: tiers[1].id,
        defaultTargetID: tiers[2].id,
        upstreamBaseURL: LiteLLMProcessManager.developmentUpstream
    )
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("routes.toml")
    try SwitchyardConfigWriter.write(profile: profile, to: target)

    let restored = try SavedRoutingSetup.migrateGeneratedConfig(from: target)

    #expect(restored.isUsable)
    #expect(restored.profile.algorithm == .llmClassifier)
    #expect(restored.profile.tiers.map(\.assignedModel) == ["gpt-fast", "gpt-mid", "gpt-strong"])
    #expect(restored.profile.classifierModel == "gpt-mid")
    #expect(restored.profile.defaultTargetName == "capable")
}

/// A file written before the `models` table still restores.
@Test func migrationStillReadsTheLegacyClassifierTargetList() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("routes.toml")
    try """
    schema_version = 1

    [llm_clients.openai]
    format = "openai_responses"
    base_url = "http://127.0.0.1:4101/v1"
    forward_auth = false

    [targets.efficient]
    id = "gpt-fast"
    llm_client = "openai"

    [targets.capable]
    id = "gpt-strong"
    llm_client = "openai"

    [routes.main]
    id = "switchyard-desktop"
    type = "llm_classifier"
    mode = "custom"
    classifier_target = "efficient"
    targets = ["efficient", "capable"]
    default_target = "capable"
    """.write(to: target, atomically: true, encoding: .utf8)

    let restored = try SavedRoutingSetup.migrateGeneratedConfig(from: target)

    #expect(restored.isUsable)
    #expect(restored.profile.classifierModel == "gpt-fast")
    #expect(restored.profile.defaultTargetName == "capable")
}

/// A route generated by an older build retains its opt-out as a client setting.
@Test func migrationRestoresTheReasoningSummariesOptOut() throws {
    var profile = RoutingProfile(
        provider: .codex,
        algorithm: .stageRouter,
        tiers: [
            TaskTier(name: "Efficient", summary: "Small work.", modelID: "gpt-fast"),
            TaskTier(name: "Capable", summary: "Hard work.", modelID: "gpt-strong"),
        ],
        upstreamBaseURL: LiteLLMProcessManager.developmentUpstream
    )
    profile.advertisesReasoningSummaries = false
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("routes.toml")
    let legacy = try SwitchyardConfigWriter.render(profile: profile)
        .replacingOccurrences(of: "[routes.main]", with: "[routes.main]\nreasoning_summaries = false")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try legacy.write(to: target, atomically: true, encoding: .utf8)

    let restored = try SavedRoutingSetup.migrateGeneratedConfig(from: target)

    #expect(!restored.profile.advertisesReasoningSummaries)
    #expect(try !SwitchyardConfigWriter.render(profile: restored.profile).contains("reasoning_summaries"))
}

// MARK: - Recovering a generated classifier's descriptions

private func generatedClassifier() -> RoutingProfile {
    let tiers = [
        TaskTier(name: "Target 1", summary: "Mechanical edits with no design choice.", modelID: "gpt-fast"),
        TaskTier(name: "Target 2", summary: "Everyday feature and bug work.", modelID: "gpt-mid"),
        TaskTier(name: "Target 3", summary: "Work that must be investigated first.", modelID: "gpt-strong"),
    ]
    return RoutingProfile(
        provider: .codex,
        algorithm: .llmClassifier,
        tiers: tiers,
        classifierTargetID: tiers[0].id,
        defaultTargetID: tiers[1].id,
        upstreamBaseURL: LiteLLMProcessManager.developmentUpstream
    )
}

private func writtenConfig(_ profile: RoutingProfile) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let target = directory.appendingPathComponent("routes.toml")
    try SwitchyardConfigWriter.write(profile: profile, to: target)
    return target
}

/// Keeping the whole route body verbatim leaves the description fields empty
/// while the prompt naming those targets is frozen out of reach, so removing a
/// target leaves the route naming one that no longer exists.
@Test func migrationPutsAGeneratedPromptsDescriptionsBackInTheirFields() throws {
    let target = try writtenConfig(generatedClassifier())
    defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }

    let restored = try SavedRoutingSetup.migrateGeneratedConfig(from: target)

    #expect(restored.profile.nativeRouteOptions == nil)
    #expect(restored.profile.tiers.map(\.summary) == [
        "Mechanical edits with no design choice.",
        "Everyday feature and bug work.",
        "Work that must be investigated first.",
    ])
    #expect(restored.profile.undescribedTiers.isEmpty)
}

/// The recovered profile has to still be the same route — and now survive the
/// target change that the frozen body could not.
@Test func aRecoveredClassifierStillRendersTheSameRouteAndSurvivesATargetChange() throws {
    let original = generatedClassifier()
    let target = try writtenConfig(original)
    defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
    var restored = try SavedRoutingSetup.migrateGeneratedConfig(from: target).profile

    #expect(try SwitchyardConfigWriter.render(profile: restored)
        == (try SwitchyardConfigWriter.render(profile: original)))

    restored.removeTier(id: try #require(restored.tiers.first).id)
    restored.defaultTargetID = restored.tiers.first?.id
    restored.classifierTargetID = restored.tiers.first?.id

    #expect(restored.roleValidationErrors.isEmpty)
    let rendered = try SwitchyardConfigWriter.render(profile: restored)
    #expect(!rendered.contains("target_1"))
}

/// Anything this app cannot reproduce stays native and untouched — a prompt
/// someone wrote by hand is not the app's to move into a field.
@Test func migrationLeavesARouteItCannotReproduceAlone() throws {
    var custom = generatedClassifier()
    custom.nativeRouteOptions = try SwitchyardConfigWriter.render(profile: custom)
        .components(separatedBy: "[routes.main]\n").last?
        .replacingOccurrences(of: "id = \"switchyard-desktop\"\n", with: "")
        .replacingOccurrences(of: "base_threshold", with: "unreproducible_threshold")
    custom.nativeRouteOptions? += "\nrecent_turn_window = 3\n"
    let target = try writtenConfig(custom)
    defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }

    let restored = try SavedRoutingSetup.migrateGeneratedConfig(from: target)

    #expect(restored.profile.nativeRouteOptions != nil)
    #expect(restored.profile.tiers.allSatisfy { $0.summary.isEmpty })
}

/// A setup saved before this recovery existed still carries its descriptions
/// only inside the frozen body.
@Test func loadingASavedSetupRecoversItsDescriptionsToo() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SavedRoutingSetupStore(fileURL: directory.appendingPathComponent("saved.json"))

    var stale = generatedClassifier()
    stale.nativeRouteOptions = try SwitchyardConfigWriter.render(profile: stale)
        .components(separatedBy: "[routes.main]\n").last?
        .replacingOccurrences(of: "id = \"switchyard-desktop\"\n", with: "")
    for index in stale.tiers.indices { stale.tiers[index].summary = "" }
    for index in stale.tiers.indices { stale.tiers[index].targetKey = "target_\(index + 1)" }
    try store.save(SavedRoutingSetup(
        profile: stale, discoveredModels: [], binaryPathOverride: "", savedAt: Date()
    ))

    let loaded = try #require(try store.load())

    #expect(loaded.profile.nativeRouteOptions == nil)
    #expect(loaded.profile.undescribedTiers.isEmpty)
}

/// Named on the step that caused it, rather than as an opaque server rejection
/// two steps later.
@Test func aNativeBodyNamingARemovedTargetIsReportedAsSuch() throws {
    var frozen = generatedClassifier()
    frozen.nativeRouteOptions = try SwitchyardConfigWriter.render(profile: frozen)
        .components(separatedBy: "[routes.main]\n").last?
        .replacingOccurrences(of: "id = \"switchyard-desktop\"\n", with: "")
    frozen.removeTier(id: try #require(frozen.tiers.first).id)

    #expect(frozen.roleValidationErrors.contains { $0.contains("target_1") })
}

/// The two decode-time migrations have an order: descriptions frozen in a
/// captured route body must come out before roles are lifted, or a profile
/// reads as having no wording and the built-ins go over the top of the user's.
@Test func descriptionsAreRecoveredBeforeRolesAreLifted() throws {
    var frozen = generatedClassifier()
    frozen.nativeRouteOptions = try SwitchyardConfigWriter.render(profile: frozen)
        .components(separatedBy: "[routes.main]\n").last?
        .replacingOccurrences(of: "id = \"switchyard-desktop\"\n", with: "")
    for index in frozen.tiers.indices {
        frozen.tiers[index].summary = ""
        frozen.tiers[index].targetKey = "target_\(index + 1)"
    }
    frozen.roles = []

    let decoded = try JSONDecoder().decode(
        RoutingProfile.self, from: try JSONEncoder().encode(frozen)
    )

    #expect(decoded.nativeRouteOptions == nil)
    #expect(decoded.roles.targets.map(\.text) == [
        "Mechanical edits with no design choice.",
        "Everyday feature and bug work.",
        "Work that must be investigated first.",
    ])
    #expect(decoded.tiers.allSatisfy { decoded.role(of: $0) != nil })
    #expect(!decoded.roles.targets.contains { $0.isBuiltIn })
}
