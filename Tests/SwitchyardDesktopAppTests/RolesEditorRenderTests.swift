import AppKit
import Foundation
import SwiftUI
import Testing
import SwitchyardDesktopKit
@testable import SwitchyardDesktopApp

private struct RolesDiscovery: CodexModelDiscovering {
    func discover(using setup: CodexSetup) throws -> [CodexSubscriptionModel] {
        [CodexSubscriptionModel(id: "gpt-5.6-luna", displayName: "GPT-5.6-Luna", isDefault: true),
         CodexSubscriptionModel(id: "gpt-6-astra", displayName: "GPT-6-Astra", isDefault: false)]
    }
}

private struct RolesSetupReader: CodexSetupReading {
    func read(configPath: URL) throws -> CodexSetup {
        CodexSetup(configPath: configPath, model: "gpt-5.6-luna", modelProvider: "openai")
    }
}

@MainActor
/// Opt-in rendering of the roles screen for visual review, with fixture models
/// and no user account or configuration.
@Test func renderRolesEditorForVisualReview() async throws {
    guard let output = ProcessInfo.processInfo.environment["SWITCHYARD_DESKTOP_RENDER_ROLES"] else { return }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let model = WizardModel(
        routingConfigPath: dir.appendingPathComponent("routes.toml"),
        codexConfigPath: dir.appendingPathComponent("config.toml"),
        sessionStore: ActiveRoutingSessionStore(fileURL: dir.appendingPathComponent("a.json")),
        savedSetupStore: SavedRoutingSetupStore(fileURL: dir.appendingPathComponent("s.json")),
        roleLibraryStore: RoleLibraryStore(fileURL: dir.appendingPathComponent("roles.json")),
        setupReader: RolesSetupReader(), modelDiscovery: RolesDiscovery(),
        cliVersionProbe: { "test" }, restoreSavedSetup: false,
        diagnostics: DiagnosticLog(url: dir.appendingPathComponent("d.log"))
    )
    await model.refreshSubscriptionModels()
    model.selectRoutingAlgorithm(.llmClassifier)
    let group = model.addRoleGroup()
    model.updateRoleGroup(RoleGroup(id: group.id, name: "Example Project", projectPath: "/fixture/project"))
    if let role = model.targetRoles.first {
        var grouped = role
        grouped.groupIDs = [group.id]
        model.updateRole(grouped)
    }

    // The judge prompt, a role this setup holds, and one only the library has:
    // the three states the screen has to read correctly.
    let cases = [
        ("classifier", model.classifierRole?.id),
        ("target", model.targetRoles.first?.id),
        ("library", model.roleLibrary.targets.first { !model.isRoleInSetup($0) }?.id),
        ("group", model.targetRoles.first?.id),
    ]
    for (name, id) in cases {
        let view = RolesEditorView(model: model, initialSelection: id,
                                   initialGroupSelection: name == "group" ? group.id : nil)
        let hosting = NSHostingView(rootView: view.frame(width: 940, height: 640))
        hosting.frame = NSRect(x: 0, y: 0, width: 940, height: 640)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).deletingPathExtension()
                .appendingPathExtension("\(name).png"))
    }
}
