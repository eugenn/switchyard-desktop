import Foundation
import Testing
@testable import SwitchyardDesktopKit

@MainActor
private final class RecordingStatusDisplay: RoutingStatusDisplaying {
    private(set) var presentations: [RoutingStatusPresentation] = []

    func update(_ presentation: RoutingStatusPresentation) {
        presentations.append(presentation)
    }
}

/// `ActiveRoutingSessionStoring` is not actor-isolated, so this stub guards its
/// own state instead of living on the main actor.
private final class LifecycleSessionStore: ActiveRoutingSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ActiveRoutingSession?

    var session: ActiveRoutingSession? {
        get {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock(); defer { lock.unlock() }
            stored = newValue
        }
    }

    func load() throws -> ActiveRoutingSession? { session }
    func save(_ session: ActiveRoutingSession) throws { self.session = session }
    func clear() throws { session = nil }
}

private func lifecycleTestDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func lifecycleTestProfile() -> RoutingProfile {
    RoutingProfile(
        provider: .codex,
        algorithm: .stageRouter,
        tiers: [
            TaskTier(name: "Efficient", summary: "Small work.", modelID: "gpt-5-mini"),
            TaskTier(name: "Capable", summary: "Hard work.", modelID: "gpt-5-codex"),
        ]
    )
}

@MainActor
@Test func inactiveRoutingDoesNotKeepTheApplicationAlive() {
    let display = RecordingStatusDisplay()
    let model = WizardModel(restoreSavedSetup: false)
    let coordinator = RoutingLifecycleCoordinator(
        model: model,
        statusDisplay: display,
        openControls: {}
    )

    #expect(!coordinator.presentation.isVisible)
    #expect(coordinator.shouldTerminateAfterLastWindowClosed)
    #expect(display.presentations.last?.isVisible == false)
}

@MainActor
@Test func aLeftoverProfileItCannotRemoveKeepsStatusVisibleAndReopensTheReview() async throws {
    let directory = try lifecycleTestDirectory()
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path
        )
        try? FileManager.default.removeItem(at: directory)
    }
    let config = directory.appendingPathComponent("config.toml")
    try "model = \"gpt-5\"\n".write(to: config, atomically: true, encoding: .utf8)
    let profilePath = directory.appendingPathComponent("switchyard-desktop.config.toml")
    try CodexProfileWriter.install(profile: lifecycleTestProfile(), profilePath: profilePath)
    let store = LifecycleSessionStore()
    try store.save(ActiveRoutingSession(
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexProfilePath: profilePath,
        startedAt: Date()
    ))
    // A launch removes a leftover profile by itself, so only one it cannot
    // delete still needs the user — here, a directory it cannot write.
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o500], ofItemAtPath: directory.path
    )
    let model = WizardModel(
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexConfigPath: config,
        codexProfilePath: profilePath,
        sessionStore: store
    )
    var opened = false
    let display = RecordingStatusDisplay()
    let coordinator = RoutingLifecycleCoordinator(
        model: model,
        statusDisplay: display,
        openControls: { opened = true }
    )

    #expect(coordinator.presentation.isVisible)
    #expect(coordinator.presentation.needsRecovery)
    #expect(!coordinator.shouldTerminateAfterLastWindowClosed)

    coordinator.reopen()
    #expect(opened)
    #expect(model.step == .confirm)
    #expect(display.presentations.last?.needsRecovery == true)
}

@MainActor
@Test func statusStopRemovesTheProfileThenTheBackgroundItem() async throws {
    let directory = try lifecycleTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent("config.toml")
    let original = "model = \"gpt-5\"\nmodel_provider = \"openai\"\n"
    try original.write(to: config, atomically: true, encoding: .utf8)
    let profilePath = directory.appendingPathComponent("switchyard-desktop.config.toml")
    try CodexProfileWriter.install(profile: lifecycleTestProfile(), profilePath: profilePath)
    let store = LifecycleSessionStore()
    try store.save(ActiveRoutingSession(
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexProfilePath: profilePath,
        startedAt: Date()
    ))
    let server = try lifecycleTestServer(in: directory)
    let manager = SwitchyardProcessManager(startupGracePeriod: .milliseconds(10))
    try await manager.start(configPath: config, binaryPath: server, port: 4102)
    let model = WizardModel(
        processManager: manager,
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexConfigPath: config,
        codexProfilePath: profilePath,
        sessionStore: store
    )
    let display = RecordingStatusDisplay()
    let coordinator = RoutingLifecycleCoordinator(
        model: model,
        statusDisplay: display,
        openControls: {}
    )

    #expect(coordinator.presentation.isVisible)
    #expect(coordinator.presentation.canStop)
    #expect(await coordinator.stopRouting())
    #expect(!FileManager.default.fileExists(atPath: profilePath.path))
    #expect(try String(contentsOf: config, encoding: .utf8) == original)
    #expect(!manager.status.isRunning)
    #expect(store.session == nil)
    #expect(!coordinator.presentation.isVisible)
    #expect(display.presentations.last?.isVisible == false)
}

private func lifecycleTestServer(in directory: URL) throws -> URL {
    let script = directory.appendingPathComponent("managed-server.sh")
    try """
    #!/bin/sh
    exec /bin/sleep 30
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: script.path
    )
    return script
}

@MainActor
@Test func activeRouterOpensStatisticsAndKeepsConfigurationExplicit() async throws {
    let directory = try lifecycleTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = SwitchyardProcessManager(startupGracePeriod: .milliseconds(10))
    defer { manager.stop() }
    try await manager.start(
        configPath: directory.appendingPathComponent("routes.toml"),
        binaryPath: lifecycleTestServer(in: directory), port: 4102
    )
    let model = WizardModel(processManager: manager, sessionStore: LifecycleSessionStore(), restoreSavedSetup: false)
    var controls = 0
    var statistics = 0
    let coordinator = RoutingLifecycleCoordinator(
        model: model, statusDisplay: RecordingStatusDisplay(),
        openControls: { controls += 1 }, openStatistics: { statistics += 1 }
    )

    coordinator.reopen()
    #expect(statistics == 1)
    #expect(controls == 0)
    #expect(model.step == .provider)
    coordinator.reopenControls()
    #expect(controls == 1)
    #expect(model.step == .confirm)

    manager.stop()
    coordinator.reopen()
    #expect(statistics == 1)
    #expect(controls == 2)
}
