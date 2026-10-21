import AppKit
import Foundation
import SwiftUI
import Testing
import SwitchyardDesktopKit
@testable import SwitchyardDesktopApp

private let fixtureModels = [
    CodexSubscriptionModel(id: "gpt-5.3-codex-spark", displayName: "GPT-5.3-Codex-Spark", isDefault: false),
    CodexSubscriptionModel(id: "gpt-5.6-luna", displayName: "GPT-5.6-Luna", isDefault: false, supportsImages: true),
    CodexSubscriptionModel(id: "gpt-5.6-terra", displayName: "GPT-5.6-Terra", isDefault: true, supportsImages: true),
    CodexSubscriptionModel(id: "gpt-6-astra", displayName: "GPT-6-Astra", isDefault: false, supportsImages: true),
]

private struct FixtureDiscovery: CodexModelDiscovering {
    func discover(using setup: CodexSetup) throws -> [CodexSubscriptionModel] { fixtureModels }
}

private struct FixtureSetupReader: CodexSetupReading {
    func read(configPath: URL) throws -> CodexSetup {
        CodexSetup(configPath: configPath, model: "gpt-5.6-terra", modelProvider: "openai")
    }
}

private struct FixtureReadiness: RoutingReadinessChecking {
    func check(profile: RoutingProfile, binaryPathOverride: String, routingConfigPath: URL,
               codexProfilePath: URL) -> RoutingReadiness {
        let passed: ReadinessStatus = .passed("Ready")
        return RoutingReadiness(routingConfigPath: routingConfigPath, codexProfilePath: codexProfilePath,
                                resolvedBinaryPath: nil, serverSupportsVision: true,
                                binary: passed, generatedConfig: passed, dryRun: passed,
                                codexProfile: passed, endpoint: passed, upstream: passed)
    }
}

/// Opt-in rendering of the setup steps for visual review, with fixture models and
/// no user account, configuration or process.
@MainActor
@Test func renderWizardForVisualReview() async throws {
    guard let output = ProcessInfo.processInfo.environment["SWITCHYARD_DESKTOP_RENDER_SETUP"] else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let model = WizardModel(
        readinessChecker: FixtureReadiness(),
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexConfigPath: directory.appendingPathComponent("config.toml"),
        sessionStore: ActiveRoutingSessionStore(fileURL: directory.appendingPathComponent("active.json")),
        savedSetupStore: SavedRoutingSetupStore(fileURL: directory.appendingPathComponent("saved.json")),
        setupReader: FixtureSetupReader(), modelDiscovery: FixtureDiscovery(),
        cliVersionProbe: { "test" }, restoreSavedSetup: false,
        diagnostics: DiagnosticLog(url: directory.appendingPathComponent("diagnostics.log"))
    )
    await model.refreshSubscriptionModels()
    model.selectRoutingAlgorithm(.llmClassifier)
    for (index, entry) in model.profile.tiers.indices.enumerated() {
        model.profile.tiers[entry].modelID = fixtureModels[min(index, fixtureModels.count - 1)].id
    }
    model.profile.classifierTargetID = model.profile.tiers.last?.id
    model.profile.defaultTargetID = model.profile.tiers.first?.id
    await model.refreshReadiness()

    let base = URL(fileURLWithPath: output).deletingPathExtension()
    for step in WizardModel.Step.allCases {
        model.step = step
        let view = WizardView(model: model)
            .frame(width: 1_100, height: 820)
            .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 1_100, height: 820)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: base.appendingPathExtension("\(step.rawValue + 1)-\(step.rawValue == 0 ? "account" : (step.rawValue == 1 ? "routing" : "review")).png"))
    }
}
