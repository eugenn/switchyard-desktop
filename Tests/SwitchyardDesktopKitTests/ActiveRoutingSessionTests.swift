import Foundation
import Testing
@testable import SwitchyardDesktopKit

private func lifecycleProfile() -> RoutingProfile {
    RoutingProfile(
        provider: .codex,
        algorithm: .stageRouter,
        tiers: [
            TaskTier(name: "Efficient", summary: "Simple.", modelID: "gpt-5-mini"),
            TaskTier(name: "Capable", summary: "Complex.", modelID: "gpt-5-codex"),
        ]
    )
}

private func lifecycleDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private final class InMemorySessionStore: ActiveRoutingSessionStoring {
    var session: ActiveRoutingSession?

    func load() throws -> ActiveRoutingSession? { session }
    func save(_ session: ActiveRoutingSession) throws { self.session = session }
    func clear() throws { session = nil }
}

/// The user's own configuration, present in every test so each one can assert
/// that this app leaves it exactly as it found it.
private let userConfig = "model = \"original\"\nmodel_provider = \"original_provider\"\n"

private func seedCodexHome(in directory: URL) throws -> (config: URL, profile: URL) {
    let config = directory.appendingPathComponent("config.toml")
    try userConfig.write(to: config, atomically: true, encoding: .utf8)
    return (config, directory.appendingPathComponent("switch.config.toml"))
}

/// A launch that finds a profile left behind by an unclean shutdown removes it
/// itself: that run's proxy is gone, so a session started with the flag would
/// reach a dead endpoint. Nothing about the user's own setup is at stake, so the
/// notice explains what happened and Start stays available.
@MainActor
@Test func startupRemovesAProfileLeftByAnUncleanShutdown() async throws {
    let directory = try lifecycleDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (config, profilePath) = try seedCodexHome(in: directory)

    try CodexProfileWriter.install(profile: lifecycleProfile(), profilePath: profilePath)
    let sessionStore = InMemorySessionStore()
    try sessionStore.save(ActiveRoutingSession(
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexProfilePath: profilePath,
        startedAt: Date()
    ))

    let model = WizardModel(
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexConfigPath: config,
        codexProfilePath: profilePath,
        sessionStore: sessionStore
    )

    #expect(!FileManager.default.fileExists(atPath: profilePath.path))
    #expect(try String(contentsOf: config, encoding: .utf8) == userConfig)
    #expect(sessionStore.session == nil)

    // Nothing is pending, so the notice explains the change without blocking.
    #expect(!model.recoveryState.needsAttention)
    #expect(model.canApply == model.discoveryState.isReady)
    #expect(model.recoveryMessage?.contains(profilePath.path) == true)
    #expect(model.requestQuit())
    #expect(!model.shouldConfirmQuit)
}

/// A record whose profile is already gone is simply dropped: there is nothing
/// left on disk for this app to own.
@MainActor
@Test func startupDropsARecordWhoseProfileIsAlreadyGone() async throws {
    let directory = try lifecycleDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (config, profilePath) = try seedCodexHome(in: directory)

    let sessionStore = InMemorySessionStore()
    try sessionStore.save(ActiveRoutingSession(
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexProfilePath: profilePath,
        startedAt: Date()
    ))

    let model = WizardModel(
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexConfigPath: config,
        codexProfilePath: profilePath,
        sessionStore: sessionStore
    )

    #expect(sessionStore.session == nil)
    #expect(!model.isApplied)
    #expect(model.recoveryMessage == nil)
}

/// A profile this app cannot delete is reported, not treated as a blocker:
/// Start writes the file again anyway, and no Codex session outside the flag is
/// affected while it sits there.
@MainActor
@Test func startupReportsAProfileItCannotRemove() async throws {
    let directory = try lifecycleDirectory()
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path
        )
        try? FileManager.default.removeItem(at: directory)
    }
    let (config, profilePath) = try seedCodexHome(in: directory)
    try CodexProfileWriter.install(profile: lifecycleProfile(), profilePath: profilePath)

    let sessionStore = InMemorySessionStore()
    try sessionStore.save(ActiveRoutingSession(
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexProfilePath: profilePath,
        startedAt: Date()
    ))
    // Removing an entry needs write permission on its directory, not the file.
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o500], ofItemAtPath: directory.path
    )

    let model = WizardModel(
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexConfigPath: config,
        codexProfilePath: profilePath,
        sessionStore: sessionStore
    )

    #expect(FileManager.default.fileExists(atPath: profilePath.path))
    #expect(model.recoveryState.needsAttention)
    #expect(model.recoveryMessage?.contains(profilePath.path) == true)
    // Reported, not blocking: Start replaces the file.
    #expect(model.canApply == model.discoveryState.isReady)
}

@MainActor
@Test func revertAndQuitRemovesTheProfileBeforeStoppingTheManagedProcess() async throws {
    let directory = try lifecycleDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (config, profilePath) = try seedCodexHome(in: directory)
    try CodexProfileWriter.install(profile: lifecycleProfile(), profilePath: profilePath)

    let sessionStore = InMemorySessionStore()
    try sessionStore.save(ActiveRoutingSession(
        routingConfigPath: config,
        codexProfilePath: profilePath,
        startedAt: Date()
    ))

    let managedServer = try lifecycleServerScript(in: directory)
    var profileExistedAtStop: Bool?
    let manager = SwitchyardProcessManager(
        startupGracePeriod: .milliseconds(10),
        beforeStop: {
            profileExistedAtStop = FileManager.default.fileExists(atPath: profilePath.path)
        }
    )
    try await manager.start(configPath: config, binaryPath: managedServer, port: 4101)
    defer { manager.stop() }

    let model = WizardModel(
        processManager: manager,
        routingConfigPath: config,
        codexConfigPath: config,
        codexProfilePath: profilePath,
        sessionStore: sessionStore
    )

    #expect(!model.requestQuit())
    #expect(await model.revertAndQuit())
    #expect(!FileManager.default.fileExists(atPath: profilePath.path))
    #expect(try String(contentsOf: config, encoding: .utf8) == userConfig)
    #expect(!manager.status.isRunning)
    #expect(profileExistedAtStop == false)
}

/// A termination the app cannot turn into a prompt — a log-out or a Force Quit
/// — still removes the generated profile, so the flag cannot reach a proxy that
/// is about to stop.
@MainActor
@Test func terminationRemovesTheProfileBeforeStoppingTheManagedProcess() async throws {
    let directory = try lifecycleDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (config, profilePath) = try seedCodexHome(in: directory)
    try CodexProfileWriter.install(profile: lifecycleProfile(), profilePath: profilePath)

    let sessionStore = InMemorySessionStore()
    try sessionStore.save(ActiveRoutingSession(
        routingConfigPath: config,
        codexProfilePath: profilePath,
        startedAt: Date()
    ))

    let managedServer = try lifecycleServerScript(in: directory)
    var profileExistedAtStop: Bool?
    let manager = SwitchyardProcessManager(
        startupGracePeriod: .milliseconds(10),
        beforeStop: {
            profileExistedAtStop = FileManager.default.fileExists(atPath: profilePath.path)
        }
    )
    try await manager.start(configPath: config, binaryPath: managedServer, port: 4101)
    defer { manager.stop() }

    let model = WizardModel(
        processManager: manager,
        routingConfigPath: config,
        codexConfigPath: config,
        codexProfilePath: profilePath,
        sessionStore: sessionStore
    )

    model.cleanUpForTermination()

    #expect(!FileManager.default.fileExists(atPath: profilePath.path))
    #expect(try String(contentsOf: config, encoding: .utf8) == userConfig)
    #expect(profileExistedAtStop == false)
    #expect(!manager.status.isRunning)
    // Nothing is left for the next launch to clean up.
    #expect(try sessionStore.load() == nil)
}

/// Stopping cannot leave the proxy down while a profile still points at it.
@MainActor
@Test func failedRemovalKeepsTheManagedProcessRunning() async throws {
    let directory = try lifecycleDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (config, profilePath) = try seedCodexHome(in: directory)
    // A file at this app's path that is not this app's: removal must refuse it.
    let foreign = "model = \"gpt-5-codex\"\nmodel_provider = \"someone_else\"\n"
    try foreign.write(to: profilePath, atomically: true, encoding: .utf8)

    let sessionStore = InMemorySessionStore()
    try sessionStore.save(ActiveRoutingSession(
        routingConfigPath: config,
        codexProfilePath: profilePath,
        startedAt: Date()
    ))

    let managedServer = try lifecycleServerScript(in: directory)
    let manager = SwitchyardProcessManager(startupGracePeriod: .milliseconds(10))
    try await manager.start(configPath: config, binaryPath: managedServer, port: 4101)
    defer { manager.stop() }

    let model = WizardModel(
        processManager: manager,
        routingConfigPath: config,
        codexConfigPath: config,
        codexProfilePath: profilePath,
        sessionStore: sessionStore
    )

    #expect(!(await model.revert()))
    #expect(manager.status.isRunning)
    #expect(try String(contentsOf: profilePath, encoding: .utf8) == foreign)
    #expect(model.recoveryMessage?.contains(profilePath.path) == true)
}

/// Upgrading while a route from a version that patched `config.toml` was active
/// is the one case where this app still writes that file — to put it back.
@MainActor
@Test func startupUndoesAConfigurationAnEarlierVersionPatched() async throws {
    let directory = try lifecycleDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent("config.toml")
    let backup = directory.appendingPathComponent("config.toml.bak-20260101-000000")
    try userConfig.write(to: backup, atomically: true, encoding: .utf8)
    try """
        model = "switchyard/auto"
        model_provider = "switchyard-desktop"

        [model_providers.switchyard-desktop]
        base_url = "http://127.0.0.1:4100/v1"
        """.write(to: config, atomically: true, encoding: .utf8)

    let recordURL = directory.appendingPathComponent("active-routing.json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(LegacyPatchedConfigSession(
        codexCapture: LegacyPatchedConfigSession.Capture(
            configPath: config,
            backupPath: backup,
            originalConfigExisted: true
        ),
        startedAt: Date()
    )).write(to: recordURL, options: .atomic)

    let model = WizardModel(
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexConfigPath: config,
        codexProfilePath: directory.appendingPathComponent("switch.config.toml"),
        sessionStore: ActiveRoutingSessionStore(fileURL: recordURL)
    )

    #expect(try String(contentsOf: config, encoding: .utf8) == userConfig)
    #expect(!FileManager.default.fileExists(atPath: recordURL.path))
    #expect(!model.recoveryState.needsAttention)
    #expect(model.recoveryMessage?.contains(config.path) == true)
    #expect(!model.isApplied)
}

private func lifecycleServerScript(in directory: URL) throws -> URL {
    let script = directory.appendingPathComponent("managed-server.sh")
    try """
    #!/bin/sh
    exec /bin/sleep 30
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    return script
}
