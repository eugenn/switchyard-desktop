import Foundation
import Testing
import TOMLKit
@testable import SwitchyardDesktopKit

private func groupFixture() throws -> RoleLibrary {
    var library = RoleLibrary.shipped
    var group = library.addGroup(name: "Example Project")
    var profile = RoutingProfile(
        algorithm: .llmClassifier,
        upstreamBaseURL: "https://chatgpt.com/backend-api/codex"
    )
    profile.tiers[0].modelID = "gpt-5.6-luna"
    profile.tiers[1].modelID = "gpt-6-astra"
    profile.classifyTrigger = .userTurn
    profile.judgeModelID = "gpt-5.6-luna"
    profile.defaultTargetID = profile.tiers[0].id

    for tier in profile.tiers {
        if let id = tier.roleID, var role = library[id: id] {
            role.groupIDs.insert(group.id)
            library.upsert(role)
        }
    }
    if var classifier = library.classifiers.first {
        classifier.groupIDs.insert(group.id)
        library.upsert(classifier)
    }
    group.routingProfile = profile
    library.updateGroup(group)
    return library
}

@Test func roleGroupsPreserveOldLibrariesAndMultipleMemberships() throws {
    let decoder = JSONDecoder()
    let legacy = try decoder.decode(RoleLibrary.self, from: Data("{\"version\":1,\"roles\":[]}".utf8))
    #expect(legacy.groups.isEmpty)
    var library = legacy
    let project = library.addGroup(name: "Project", projectPath: "/fixture/project")
    let reusable = library.addGroup(name: "Research")
    var role = library.add(name: "Analyst", text: "Inspect evidence.", tags: ["analysis"])
    role.groupIDs = [project.id, reusable.id]
    library.upsert(role)
    let duplicated = library.duplicate(id: role.id)
    let copy = try #require(duplicated)
    #expect(copy.groupIDs == role.groupIDs)
    #expect(library.filtered(search: "evidence", tag: "analysis", groupID: project.id).count == 2)
    #expect(library.filtered(tag: "coding", groupID: project.id).isEmpty)

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = RoleLibraryStore(fileURL: dir.appendingPathComponent("roles.json"))
    try store.save(library)
    var restored = try #require(try store.load())
    #expect(restored.groups == library.groups)
    #expect(restored[id: role.id]?.groupIDs == role.groupIDs)
    restored.removeGroup(id: project.id)
    #expect(restored[id: role.id]?.groupIDs == [reusable.id])
    #expect(restored[id: copy.id]?.groupIDs == [reusable.id])
    #expect(restored.filtered(groupID: reusable.id).count == 2)
}

@Test func groupingAndResettingShippedRolesKeepsMembership() throws {
    var library = RoleLibrary.shipped
    let group = library.addGroup(name: "Project")
    var role = try #require(library.targets.first)
    role.groupIDs.insert(group.id)
    library.upsert(role)
    #expect(!library.isEdited(role))
    role.systemPrompt = "An edited prompt."
    library.upsert(role)
    #expect(library.isEdited(role))
    let resetRole = library.resetToBuiltIn(id: role.id)
    let reset = try #require(resetRole)
    #expect(reset.groupIDs == [group.id])
    #expect(!library.isEdited(reset))
}

@Test func roleGroupGeneratesClassifierRoute() throws {
    let library = try groupFixture()
    let group = try #require(library.groups.first)
    let profile = try #require(group.routingProfile)
    #expect(profile.isValid)
    #expect(library.filtered(groupID: group.id).count == 3)
    #expect(profile.algorithm == .llmClassifier)
    #expect(profile.classifyTrigger == .userTurn)
    #expect(profile.classifierModel == "gpt-5.6-luna")
    #expect(profile.defaultTargetName == profile.targetNames[0])
    #expect(Set(profile.tiers.compactMap(\.modelID)) == ["gpt-6-astra", "gpt-5.6-luna"])
    let text = try SwitchyardConfigWriter.render(profile: profile)
    let table = try TOMLTable(string: text)
    let route = try #require(table["routes"]?.table?["main"]?.table)
    #expect(route["default_target"]?.string == profile.targetNames[0])
    #expect(route["classify_trigger"]?.string == "user_turn")
    #expect(route["policy"]?.table?["selector"]?.string == "/decision/target")
    #expect(!text.contains("{{targets}}"))
    #expect(!text.contains("{{target_names}}"))
    let targets = try #require(table["targets"]?.table)
    for name in profile.targetNames {
        #expect(targets[name]?.table?["llm_client"]?.string == "openai")
        #expect(targets[name]?.table?["system_prompt"]?.string != nil)
    }
    #expect(profile.upstreamBaseURL == "https://chatgpt.com/backend-api/codex")
    #expect(profile.forwardsCallerCredential)
    #expect(!profile.usesManagedLiteLLM)
    #expect(profile.routesJudgeThroughLiteLLM)
    let clients = try #require(table["llm_clients"]?.table)
    #expect(clients["openai"]?.table?["forward_auth"]?.bool == true)
    #expect(clients["judge_litellm"]?.table?["base_url"]?.string == "http://127.0.0.1:4101/v1")
    let judge = try #require(profile.judgeTargetName)
    #expect(targets[judge]?.table?["llm_client"]?.string == "judge_litellm")
    #expect(targets[judge]?.table?["id"]?.string == "judge-gpt-5.6-luna")
    #expect(profile.managedLiteLLMModels?.count == 1)
    #expect(profile.managedLiteLLMModels?.contains(
        LiteLLMModel("judge-gpt-5.6-luna", servedBy: "gpt-5.6-luna")) == true)
    #expect(targets[judge]?.table?["reasoning_effort"]?.string == "low")
    #expect(targets[judge]?.table?["system_prompt"] == nil)
    // Opt-in output for the server's own dry-run; never a real user config.
    if let output = ProcessInfo.processInfo.environment["SWITCHYARD_DESKTOP_EXPORT_GROUP_CONFIG"] {
        try text.write(toFile: output, atomically: true, encoding: .utf8)
    }
}

@MainActor
@Test func projectSetupLoadsAsDraftAndTakesCurrentLibraryPrompts() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = RoleLibraryStore(fileURL: dir.appendingPathComponent("roles.json"))
    var library = try groupFixture()
    // Project folders are metadata, never resolved by this test or the model.
    library.groups[0].projectPath = "/fixture/project"
    let group = library.groups[0]
    let original = try #require(group.routingProfile)
    let roleID = try #require(original.tiers.first { $0.modelID == "gpt-6-astra" }?.roleID)
    var role = try #require(library[id: roleID])
    role.systemPrompt = "New library wording, newer than the saved group."
    library.upsert(role)
    try store.save(library)
    let model = WizardModel(
        routingConfigPath: dir.appendingPathComponent("routes.toml"),
        codexConfigPath: dir.appendingPathComponent("config.toml"),
        codexProfilePath: dir.appendingPathComponent("profile.toml"),
        sessionStore: ActiveRoutingSessionStore(fileURL: dir.appendingPathComponent("session.json")),
        savedSetupStore: SavedRoutingSetupStore(fileURL: dir.appendingPathComponent("setup.json")),
        roleLibraryStore: store, cliVersionProbe: { "test" }, restoreSavedSetup: false,
        diagnostics: DiagnosticLog(url: dir.appendingPathComponent("diagnostics.log"))
    )
    // The one-click list a wizard step offers has to name this group before
    // anyone opens the roles editor to find it.
    #expect(model.groupsWithSavedSetup.map(\.id) == [group.id])
    #expect(model.loadRoleGroupSetup(id: group.id))
    #expect(model.profile.roles[id: roleID]?.systemPrompt == role.systemPrompt)
    #expect(model.profile.defaultTargetName == original.defaultTargetName)
    #expect(!model.isApplied)
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("routes.toml").path))
    let second = model.addRoleGroup()
    // A fresh group has nothing to load yet, so it stays off that list.
    #expect(model.groupsWithSavedSetup.map(\.id) == [group.id])
    model.saveSetupToRoleGroup(id: second.id)
    #expect(model.roleLibrary.filtered(groupID: second.id).count == 3)
    #expect(model.roleLibrary.groups.first { $0.id == second.id }?.routingProfile?.isValid == true)
    #expect(Set(model.groupsWithSavedSetup.map(\.id)) == [group.id, second.id])
    model.removeRoleGroup(id: group.id)
    #expect(model.groupsWithSavedSetup.map(\.id) == [second.id])
    #expect(model.loadRoleGroupSetup(id: second.id))
    #expect(model.profile.roles.allSatisfy { !$0.groupIDs.contains(group.id) })
    #expect(try store.load()?.groups.map(\.id) == [second.id])
}
