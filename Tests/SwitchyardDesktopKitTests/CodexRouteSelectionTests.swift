import Foundation
import Testing
@testable import SwitchyardDesktopKit

/// The generated profile layer is this app's own file, but nothing stops a user
/// from editing or deleting it while a route runs. These tests cover what that
/// does: it is reported, it is repaired by generating the file again, the user's
/// own configuration is never involved, and a profile left behind by an earlier
/// run is removed at the next launch.

private func selectionTestDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private let selectionModels = [
    CodexSubscriptionModel(id: "gpt-fast", displayName: "Fast", isDefault: true),
    CodexSubscriptionModel(id: "gpt-strong", displayName: "Strong", isDefault: false),
]

private func selectionProfile() -> RoutingProfile {
    RoutingProfile(
        provider: .codex,
        algorithm: .stageRouter,
        tiers: [
            TaskTier(name: "Efficient", summary: "Small work.", modelID: selectionModels[0].id),
            TaskTier(name: "Capable", summary: "Hard work.", modelID: selectionModels[1].id),
        ],
        upstreamBaseURL: LiteLLMProcessManager.developmentUpstream
    )
}

/// Codex settings the user owns, present in every test so each one can check
/// that no repair, revert or recovery ever reaches them.
private let userOwnedConfig = """
    model = "gpt-5.6-sol"
    model_provider = "openai"
    model_reasoning_effort = "xhigh"

    [projects."/Users/someone/work"]
    trust_level = "trusted"

    """

private struct SelectionReadyChecker: RoutingReadinessChecking {
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

private struct SelectionSetupReader: CodexSetupReading {
    func read(configPath: URL) throws -> CodexSetup {
        CodexSetup(configPath: configPath, model: "gpt-fast", modelProvider: "openai")
    }
}

private struct SelectionDiscovery: CodexModelDiscovering {
    func discover(using _: CodexSetup) throws -> [CodexSubscriptionModel] { selectionModels }
}

private final class SelectionSessionStore: ActiveRoutingSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ActiveRoutingSession?

    var session: ActiveRoutingSession? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }

    func load() throws -> ActiveRoutingSession? { session }
    func save(_ session: ActiveRoutingSession) throws { self.session = session }
    func clear() throws { session = nil }
}

private final class SelectionSetupStore: SavedRoutingSetupStoring {
    var setup: SavedRoutingSetup?

    func load() throws -> SavedRoutingSetup? { setup }
    func save(_ setup: SavedRoutingSetup) throws { self.setup = setup }
    func clear() throws { setup = nil }
}

private func selectionTestServer(in directory: URL) throws -> URL {
    let binary = directory.appendingPathComponent("switchyard-server")
    try """
    #!/bin/sh
    for argument in "$@"; do
      if [ "$argument" = "--dry-run" ]; then exit 0; fi
    done
    exec /bin/sleep 30
    """.write(to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    return binary
}

/// A model with a route this app really applied: the profile layer is written
/// and the managed process is running, exactly as it is when a file is edited
/// underneath it.
@MainActor
private func routedModel(in directory: URL, port: Int) async throws -> WizardModel {
    let codexConfig = directory.appendingPathComponent("config.toml")
    try userOwnedConfig.write(to: codexConfig, atomically: true, encoding: .utf8)
    let model = WizardModel(
        processManager: SwitchyardProcessManager(startupGracePeriod: .milliseconds(10)),
        readinessChecker: SelectionReadyChecker(binary: try selectionTestServer(in: directory)),
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexConfigPath: codexConfig,
        codexProfilePath: directory.appendingPathComponent("switch.config.toml"),
        sessionStore: SelectionSessionStore(),
        // Every store is injected: a default one would reach for a location
        // this process shares with the running app.
        savedSetupStore: SelectionSetupStore(),
        setupReader: SelectionSetupReader(),
        modelDiscovery: SelectionDiscovery(),
        restoreSavedSetup: false
    )
    model.profile = selectionProfile()
    model.profile.port = port
    await model.discoverSubscriptionModelsIfNeeded()
    await model.apply()
    #expect(model.isApplied)
    return model
}

// MARK: - Detection

@MainActor
@Test func anEditedModelIsReportedAgainstTheRunningRoute() async throws {
    let directory = try selectionTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = try await routedModel(in: directory, port: 52_801)
    defer { model.processManager.stop() }
    #expect(model.codexDrift == nil)

    try String(contentsOf: model.codexProfilePath, encoding: .utf8)
        .replacingOccurrences(of: "model = \"switchyard-desktop\"", with: "model = \"gpt-5.6-sol\"")
        .write(to: model.codexProfilePath, atomically: true, encoding: .utf8)

    await model.refreshCodexSelection()

    #expect(model.codexDrift == .modelReplaced(selected: "gpt-5.6-sol", routeID: "switchyard-desktop"))
    #expect(model.codexDrift?.message.contains("gpt-5.6-sol") == true)
}

@MainActor
@Test func aProviderSwitchIsReportedAsBypassingTheRoute() async throws {
    let directory = try selectionTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = try await routedModel(in: directory, port: 52_802)
    defer { model.processManager.stop() }

    try String(contentsOf: model.codexProfilePath, encoding: .utf8)
        .replacingOccurrences(
            of: "model_provider = \"switchyard-desktop\"", with: "model_provider = \"openai\""
        )
        .write(to: model.codexProfilePath, atomically: true, encoding: .utf8)

    await model.refreshCodexSelection()

    #expect(model.codexDrift == .providerReplaced(selected: "openai"))
}

/// A deleted profile is the one drift the old design could not have: the route
/// runs, but `codex --profile switch` has nothing to resolve.
@MainActor
@Test func aDeletedProfileIsReportedAsAMissingRoute() async throws {
    let directory = try selectionTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = try await routedModel(in: directory, port: 52_805)
    defer { model.processManager.stop() }

    try FileManager.default.removeItem(at: model.codexProfilePath)
    await model.refreshCodexSelection()

    #expect(model.codexDrift == .profileMissing)
    #expect(model.codexDrift?.message.contains(CodexLocations.launchCommand) == true)
}

@MainActor
@Test func nothingDriftsWhileNoRouteIsApplied() {
    let model = WizardModel(restoreSavedSetup: false)

    model.updateCodexSelection(CodexRouteSelection(model: "gpt-5.6-sol", provider: "openai"))

    #expect(model.codexDrift == nil)
}

// MARK: - Repair

@MainActor
@Test func repairingTheProfileRewritesOnlyThisAppsOwnFile() async throws {
    let directory = try selectionTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = try await routedModel(in: directory, port: 52_803)
    defer { model.processManager.stop() }
    let generated = try String(contentsOf: model.codexProfilePath, encoding: .utf8)
    try generated
        .replacingOccurrences(of: "model = \"switchyard-desktop\"", with: "model = \"gpt-5.6-sol\"")
        .write(to: model.codexProfilePath, atomically: true, encoding: .utf8)
    await model.refreshCodexSelection()
    #expect(model.codexDrift != nil)

    #expect(await model.repairCodexSelection())

    #expect(model.codexDrift == nil)
    #expect(model.codexRepairError == nil)
    #expect(try String(contentsOf: model.codexProfilePath, encoding: .utf8) == generated)
    // The user's own configuration was not read, written or backed up for any
    // of this, and stopping leaves nothing of this app's behind.
    #expect(try String(contentsOf: model.codexConfigPath, encoding: .utf8) == userOwnedConfig)
    #expect(await model.revert())
    #expect(!FileManager.default.fileExists(atPath: model.codexProfilePath.path))
    #expect(try String(contentsOf: model.codexConfigPath, encoding: .utf8) == userOwnedConfig)
}

/// Repairing a deleted profile is the same operation as writing it the first
/// time: the file is generated whole, never merged.
@MainActor
@Test func repairingAMissingProfileGeneratesItAgain() async throws {
    let directory = try selectionTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = try await routedModel(in: directory, port: 52_806)
    defer { model.processManager.stop() }
    let generated = try String(contentsOf: model.codexProfilePath, encoding: .utf8)
    try FileManager.default.removeItem(at: model.codexProfilePath)
    await model.refreshCodexSelection()
    #expect(model.codexDrift == .profileMissing)

    #expect(await model.repairCodexSelection())

    #expect(model.codexDrift == nil)
    #expect(try String(contentsOf: model.codexProfilePath, encoding: .utf8) == generated)
}

@Test func generatingOverAMalformedProfileReplacesItWholesale() throws {
    let directory = try selectionTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let profilePath = directory.appendingPathComponent("switch.config.toml")
    try "model = \"unterminated\nmodel_provider = switchyard-desktop\n"
        .write(to: profilePath, atomically: true, encoding: .utf8)

    try CodexProfileWriter.install(profile: selectionProfile(), profilePath: profilePath)

    let selection = try #require(CodexProfileWriter.readSelection(profilePath: profilePath))
    #expect(selection.selectsManagedProvider)
}

// MARK: - Recovery

/// Recovery is keyed on the provider, not the route id: a profile whose `model`
/// was edited is still the file this app wrote, and still its job to remove.
@MainActor
@Test func aLaunchRemovesAProfileWhoseModelWasEdited() throws {
    let directory = try selectionTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent("config.toml")
    try userOwnedConfig.write(to: config, atomically: true, encoding: .utf8)
    let profilePath = directory.appendingPathComponent("switch.config.toml")
    try CodexProfileWriter.install(profile: selectionProfile(), profilePath: profilePath)
    try String(contentsOf: profilePath, encoding: .utf8)
        .replacingOccurrences(of: "model = \"switchyard-desktop\"", with: "model = \"gpt-5.6-sol\"")
        .write(to: profilePath, atomically: true, encoding: .utf8)

    let store = SelectionSessionStore()
    let session = ActiveRoutingSession(
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexProfilePath: profilePath,
        startedAt: Date()
    )
    try store.save(session)
    #expect(session.requiresCleanUp())

    let model = WizardModel(
        routingConfigPath: session.routingConfigPath,
        codexConfigPath: config,
        codexProfilePath: profilePath,
        sessionStore: store,
        restoreSavedSetup: false
    )

    #expect(!FileManager.default.fileExists(atPath: profilePath.path))
    #expect(try String(contentsOf: config, encoding: .utf8) == userOwnedConfig)
    #expect(store.session == nil)
    #expect(!model.isApplied)
    if case .cleanedUp = model.recoveryState {} else {
        Issue.record("Expected the abandoned profile to be removed, got \(model.recoveryState)")
    }
}

@Test func aProfilePointedAtAnotherProviderIsNotThisAppsToRemove() throws {
    let directory = try selectionTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let profilePath = directory.appendingPathComponent("switch.config.toml")
    try CodexProfileWriter.install(profile: selectionProfile(), profilePath: profilePath)
    try String(contentsOf: profilePath, encoding: .utf8)
        .replacingOccurrences(
            of: "model_provider = \"switchyard-desktop\"", with: "model_provider = \"openai\""
        )
        .write(to: profilePath, atomically: true, encoding: .utf8)

    let session = ActiveRoutingSession(
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexProfilePath: profilePath,
        startedAt: Date()
    )

    #expect(!session.requiresCleanUp())
    #expect(!CodexProfileWriter.isInstalled(profilePath: profilePath))
}

// MARK: - Background surface

/// The window is usually closed when something edits the file, so the menu-bar
/// item is the only thing on screen: it warns, and a click lands on the repair.
@MainActor
@Test func driftWarnsInTheStatusItemAndOpensTheControls() async throws {
    let directory = try selectionTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = try await routedModel(in: directory, port: 52_804)
    defer { model.processManager.stop() }
    var controls = 0
    var statistics = 0
    let coordinator = RoutingLifecycleCoordinator(
        model: model, statusDisplay: SelectionStatusDisplay(),
        openControls: { controls += 1 }, openStatistics: { statistics += 1 }
    )
    coordinator.reopen()
    #expect(statistics == 1)
    #expect(!coordinator.presentation.needsAttention)

    try String(contentsOf: model.codexProfilePath, encoding: .utf8)
        .replacingOccurrences(of: "model = \"switchyard-desktop\"", with: "model = \"gpt-5.6-sol\"")
        .write(to: model.codexProfilePath, atomically: true, encoding: .utf8)
    await model.refreshCodexSelection()

    #expect(coordinator.presentation.needsAttention)
    #expect(!coordinator.presentation.needsRecovery)
    #expect(coordinator.presentation.title == "Codex profile selects another model - open controls")
    coordinator.reopen()
    #expect(controls == 1)
    #expect(statistics == 1)
}

@MainActor
private final class SelectionStatusDisplay: RoutingStatusDisplaying {
    func update(_ presentation: RoutingStatusPresentation) {}
}
