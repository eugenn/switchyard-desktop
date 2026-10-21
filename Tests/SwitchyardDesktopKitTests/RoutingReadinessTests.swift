import Foundation
import Testing
@testable import SwitchyardDesktopKit

private func preflightProfile(port: Int) -> RoutingProfile {
    RoutingProfile(
        provider: .codex,
        algorithm: .stageRouter,
        tiers: [
            TaskTier(name: "Efficient", summary: "Simple.", modelID: "gpt-5-mini"),
            TaskTier(name: "Capable", summary: "Complex.", modelID: "gpt-5-codex"),
        ],
        port: port
    )
}

private func makePreflightDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// This accepts the dry-run arguments but never starts a listener or contacts an upstream.
private func makeDryRunStub(exitCode: Int32 = 0) throws -> URL {
    let directory = try makePreflightDirectory()
    let binary = directory.appendingPathComponent(SwitchyardBinaryLocator.binaryName)
    try """
    #!/bin/sh
    echo "stub dry-run"
    exit \(exitCode)
    """.write(to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    return binary
}

private func availableTestPort() -> Int {
    for port in 54000...55000 where RoutingReadinessChecker.isPortAvailable(
        host: RoutingProfile.defaultHost,
        port: port
    ) {
        return port
    }
    fatalError("No local test port was available")
}

@Test func readinessReportsAllRequiredChecksWithoutStartingAProxy() throws {
    let binary = try makeDryRunStub()
    let directory = try makePreflightDirectory()
    defer {
        try? FileManager.default.removeItem(at: binary.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: directory)
    }

    let readiness = RoutingReadinessChecker(liteLLMAvailable: { true }, binaryLocator: { _ in binary }).check(
        profile: preflightProfile(port: availableTestPort()),
        binaryPathOverride: binary.path,
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexProfilePath: directory.appendingPathComponent("switchyard-desktop.config.toml")
    )

    #expect(readiness.resolvedBinaryPath == binary)
    #expect(readiness.binary.isPassed)
    #expect(readiness.generatedConfig.isPassed)
    #expect(readiness.dryRun.isPassed)
    #expect(readiness.codexProfile.isPassed)
    #expect(readiness.endpoint.isPassed)
    #expect(readiness.upstream.isPassed, "upstream: \(readiness.upstream.message)")
    #expect(readiness.isReady)
}

@Test func readinessExplainsMissingServerWithoutTryingToInstallIt() throws {
    let directory = try makePreflightDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let readiness = RoutingReadinessChecker(liteLLMAvailable: { true }, binaryLocator: { _ in nil }).check(
        profile: preflightProfile(port: availableTestPort()),
        binaryPathOverride: "",
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexProfilePath: directory.appendingPathComponent("switchyard-desktop.config.toml")
    )

    #expect(readiness.resolvedBinaryPath == nil)
    #expect(!readiness.binary.isPassed)
    #expect(!readiness.dryRun.isPassed)
    #expect(!readiness.isReady)
    #expect(readiness.failureDescription.contains("Reinstall switchyard-desktop"))
}

@Test func readinessRejectsPublicListenerAndCredentialBearingUpstreamURL() throws {
    let binary = try makeDryRunStub()
    let directory = try makePreflightDirectory()
    defer {
        try? FileManager.default.removeItem(at: binary.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: directory)
    }
    var profile = preflightProfile(port: availableTestPort())
    profile.host = "0.0.0.0"
    profile.upstreamBaseURL = "https://token@example.test/v1?api_key=secret"

    let readiness = RoutingReadinessChecker(liteLLMAvailable: { true }, binaryLocator: { _ in binary }).check(
        profile: profile,
        binaryPathOverride: binary.path,
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexProfilePath: directory.appendingPathComponent("switchyard-desktop.config.toml")
    )

    #expect(!readiness.endpoint.isPassed)
    #expect(!readiness.upstream.isPassed)
    #expect(!readiness.isReady)
}

private struct FailingReadinessChecker: RoutingReadinessChecking {
    func check(
        profile: RoutingProfile,
        binaryPathOverride: String,
        routingConfigPath: URL,
        codexProfilePath: URL
    ) -> RoutingReadiness {
        RoutingReadiness(
            routingConfigPath: routingConfigPath,
            codexProfilePath: codexProfilePath,
            resolvedBinaryPath: nil,
            serverSupportsVision: false,
            binary: .failed("switchyard-server is missing."),
            generatedConfig: .skipped("Waiting for switchyard-server."),
            dryRun: .skipped("Waiting for switchyard-server."),
            codexProfile: .passed("Writable."),
            endpoint: .passed("Available."),
            upstream: .passed("Valid.")
        )
    }
}

private struct ReadySetupReader: CodexSetupReading {
    let configPath: URL

    func read(configPath _: URL) throws -> CodexSetup {
        CodexSetup(configPath: configPath, model: "gpt-5-mini", modelProvider: "openai")
    }
}

private struct ReadyModelDiscovery: CodexModelDiscovering {
    func discover(using _: CodexSetup) throws -> [CodexSubscriptionModel] {
        [
            CodexSubscriptionModel(id: "gpt-5-mini", displayName: nil, isDefault: true),
            CodexSubscriptionModel(id: "gpt-5-codex", displayName: nil, isDefault: false),
        ]
    }
}

@MainActor
@Test func failedReadinessWritesNoCodexProfileAndLeavesTheConfigurationAlone() async throws {
    let directory = try makePreflightDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let codexConfig = directory.appendingPathComponent("config.toml")
    let original = "model = \"original\"\nmodel_provider = \"existing\"\n"
    try original.write(to: codexConfig, atomically: true, encoding: .utf8)
    let codexProfile = directory.appendingPathComponent("switchyard-desktop.config.toml")

    let model = WizardModel(
        readinessChecker: FailingReadinessChecker(),
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexConfigPath: codexConfig,
        codexProfilePath: codexProfile,
        setupReader: ReadySetupReader(configPath: codexConfig),
        modelDiscovery: ReadyModelDiscovery()
    )
    model.profile = preflightProfile(port: availableTestPort())
    await model.refreshSubscriptionModels()

    await model.apply()

    #expect(try String(contentsOf: codexConfig, encoding: .utf8) == original)
    #expect(!FileManager.default.fileExists(atPath: codexProfile.path))
    #expect(!FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("routes.toml").path
    ))
    #expect(!model.processManager.status.isRunning)
    guard case .failed(let message) = model.applyState else {
        Issue.record("Expected failed preflight state")
        return
    }
    #expect(message.contains("switchyard-server is missing"))
}

@MainActor
@Test func invalidRoleConfigurationWritesNoCodexProfileAndStartsNoProxy() async throws {
    let directory = try makePreflightDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let codexConfig = directory.appendingPathComponent("config.toml")
    let original = "model = \"original\"\nmodel_provider = \"existing\"\n"
    try original.write(to: codexConfig, atomically: true, encoding: .utf8)
    let codexProfile = directory.appendingPathComponent("switchyard-desktop.config.toml")

    let model = WizardModel(
        readinessChecker: FailingReadinessChecker(),
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexConfigPath: codexConfig,
        codexProfilePath: codexProfile,
        setupReader: ReadySetupReader(configPath: codexConfig),
        modelDiscovery: ReadyModelDiscovery()
    )
    await model.refreshSubscriptionModels()
    model.selectRoutingAlgorithm(.llmClassifier)
    model.profile.tiers[0].modelID = "gpt-5-mini"
    model.profile.tiers[1].modelID = "gpt-5-codex"
    // The required classifier and fallback role choices are intentionally absent.

    await model.apply()

    #expect(try String(contentsOf: codexConfig, encoding: .utf8) == original)
    #expect(!FileManager.default.fileExists(atPath: codexProfile.path))
    #expect(!FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("routes.toml").path
    ))
    #expect(!model.processManager.status.isRunning)
    guard case .failed(let message) = model.applyState else {
        Issue.record("Expected invalid role configuration to fail")
        return
    }
    #expect(message.contains("Choose which model decides the routing"))
}


/// Rejects any config that declares image input, like a build from before the
/// route `vision` key existed.
private func makeVisionBlindStub() throws -> URL {
    let directory = try makePreflightDirectory()
    let binary = directory.appendingPathComponent(SwitchyardBinaryLocator.binaryName)
    try #"""
    #!/bin/sh
    config=""
    while [ $# -gt 0 ]; do
      if [ "$1" = "--config" ]; then config="$2"; shift 2; else shift; fi
    done
    if grep -q "^vision" "$config"; then
      echo "unknown field vision" >&2
      exit 1
    fi
    echo "stub dry-run"
    """#.write(to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    return binary
}

private func imageCapablePreflightProfile(port: Int) -> RoutingProfile {
    var profile = preflightProfile(port: port)
    profile.imageCapableModelIDs = Set(profile.tiers.compactMap(\.assignedModel))
    return profile
}

@Test func readinessFallsBackToATextOnlyRouteOnAServerWithoutTheVisionKey() throws {
    let binary = try makeVisionBlindStub()
    let directory = try makePreflightDirectory()
    defer {
        try? FileManager.default.removeItem(at: binary.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: directory)
    }

    let readiness = RoutingReadinessChecker(liteLLMAvailable: { true }, binaryLocator: { _ in binary }).check(
        profile: imageCapablePreflightProfile(port: availableTestPort()),
        binaryPathOverride: binary.path,
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexProfilePath: directory.appendingPathComponent("switchyard-desktop.config.toml")
    )

    // The route loses image input rather than the whole apply failing.
    #expect(readiness.dryRun.isPassed)
    #expect(!readiness.serverSupportsVision)
    #expect(readiness.dryRun.message.contains("does not take the route `vision` key"))
}

@Test func readinessKeepsImageInputOnAServerThatTakesTheKey() throws {
    let binary = try makeDryRunStub()
    let directory = try makePreflightDirectory()
    defer {
        try? FileManager.default.removeItem(at: binary.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: directory)
    }

    let readiness = RoutingReadinessChecker(liteLLMAvailable: { true }, binaryLocator: { _ in binary }).check(
        profile: imageCapablePreflightProfile(port: availableTestPort()),
        binaryPathOverride: binary.path,
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexProfilePath: directory.appendingPathComponent("switchyard-desktop.config.toml")
    )

    #expect(readiness.dryRun.isPassed)
    #expect(readiness.serverSupportsVision)
}

@Test func theInstalledServerEitherTakesTheVisionKeyOrSaysItDoesNot() throws {
    // Against whatever switchyard-server this machine has: a vision-capable
    // profile must still dry-run clean, either with the key or without it.
    guard let binary = SwitchyardBinaryLocator.locate() else { return }
    let directory = try makePreflightDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let readiness = RoutingReadinessChecker(liteLLMAvailable: { true }, ).check(
        profile: imageCapablePreflightProfile(port: availableTestPort()),
        binaryPathOverride: binary.path,
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexProfilePath: directory.appendingPathComponent("switchyard-desktop.config.toml")
    )

    #expect(readiness.dryRun.isPassed)
    #expect(
        readiness.serverSupportsVision
            || readiness.dryRun.message.contains("does not take the route `vision` key")
    )
}

@Test func missingBundledLiteLLMFailsReadinessBeforeStart() throws {
    let directory = try makePreflightDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let checker = RoutingReadinessChecker(liteLLMAvailable: { false }, binaryLocator: { _ in nil })
    let readiness = checker.check(
        profile: RoutingProfile(algorithm: .stageRouter),
        binaryPathOverride: "",
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexProfilePath: directory.appendingPathComponent("switchyard-desktop.config.toml")
    )
    #expect(!readiness.isReady)
    #expect(readiness.upstream.message.contains("runtime"))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.toml").path))
}

@Test func externalLoopbackLiteLLMDoesNotRequireBundledRuntime() throws {
    let binary = try makeDryRunStub()
    let directory = try makePreflightDirectory()
    defer {
        try? FileManager.default.removeItem(at: binary.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: directory)
    }
    var profile = preflightProfile(port: availableTestPort())
    profile.upstreamBaseURL = "http://127.0.0.1:4001/v1"
    let checker = RoutingReadinessChecker(
        liteLLMAvailable: { false },
        binaryLocator: { _ in binary }
    )

    let readiness = checker.check(
        profile: profile,
        binaryPathOverride: binary.path,
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexProfilePath: directory.appendingPathComponent("switchyard-desktop.config.toml")
    )

    #expect(readiness.upstream.isPassed)
    #expect(readiness.isReady)
}
