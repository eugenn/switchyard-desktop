import Foundation
import Testing
import TOMLKit
@testable import SwitchyardDesktopKit

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("role-library-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let libraryModels = [
    CodexSubscriptionModel(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra", isDefault: false),
    CodexSubscriptionModel(id: "gpt-6-astra", displayName: "GPT-6 Astra", isDefault: true),
]

private let librarySetup = CodexSetup(
    configPath: URL(fileURLWithPath: "/tmp/switchyard-desktop-role-library/config.toml"),
    model: "gpt-5.6-terra",
    modelProvider: "openai"
)

private struct LibrarySetupReader: CodexSetupReading {
    func read(configPath: URL) throws -> CodexSetup { librarySetup }
}

private struct LibraryDiscovery: CodexModelDiscovering {
    func discover(using _: CodexSetup) throws -> [CodexSubscriptionModel] { libraryModels }
}

/// Two assigned targets with the judge and fallback chosen: the smallest
/// classifier profile the writer and the saved-setup check both accept.
private func classifierProfile() -> RoutingProfile {
    let tiers = [
        TaskTier(name: "One", summary: "First.", modelID: libraryModels[0].id),
        TaskTier(name: "Two", summary: "Second.", modelID: libraryModels[1].id),
    ]
    return RoutingProfile(
        provider: .codex,
        algorithm: .llmClassifier,
        tiers: tiers,
        classifierTargetID: tiers[0].id,
        defaultTargetID: tiers[1].id
    )
}

@MainActor
private func modelWithLibrary(in directory: URL) -> WizardModel {
    WizardModel(
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexConfigPath: librarySetup.configPath,
        codexProfilePath: directory.appendingPathComponent("profile.toml"),
        sessionStore: ActiveRoutingSessionStore(fileURL: directory.appendingPathComponent("session.json")),
        savedSetupStore: SavedRoutingSetupStore(fileURL: directory.appendingPathComponent("setup.json")),
        roleLibraryStore: RoleLibraryStore(fileURL: directory.appendingPathComponent("roles.json")),
        setupReader: LibrarySetupReader(),
        modelDiscovery: LibraryDiscovery(),
        cliVersionProbe: { "test" },
        restoreSavedSetup: false,
        diagnostics: DiagnosticLog(url: directory.appendingPathComponent("diagnostics.log"))
    )
}

// MARK: - The shipped catalog

/// The roles this app ships are the answer to a setup starting empty. Every one
/// of them has to be usable as it stands: named uniquely, described for the
/// judge, and — for the ones a mode is built from — carrying the prompt the
/// model is actually sent.
@Test func theShippedCatalogIsUsableAsItStands() throws {
    let catalog = RoutingRole.builtInCatalog

    #expect(Set(catalog.map(\.id)).count == catalog.count)
    #expect(Set(catalog.map { $0.displayName.lowercased() }).count == catalog.count)
    let everyRoleIsShipped = catalog.allSatisfy(\.isBuiltIn)
    #expect(everyRoleIsShipped)
    #expect(catalog.filter { $0.kind == .classifier }.count == 1)
    let everyTargetIsDescribed = catalog.targets.allSatisfy(\.isDescribed)
    #expect(everyTargetIsDescribed)
    #expect(catalog.count > RoutingRole.builtIns.count)

    let classifier = try #require(catalog.classifier)
    #expect(classifier.rendersTargets)
    // A judge prompt is the judge's own instructions, not a model's.
    #expect(classifier.modelPrompt == nil)
    let everyOfferedRoleHasAPrompt = (RoutingRole.builtInPresetRoles + RoutingRole.builtInLibraryExtras)
        .allSatisfy { $0.modelPrompt != nil }
    #expect(everyOfferedRoleHasAPrompt)
}

// MARK: - Storage

/// The library is the user's writing. A launch may add roles a newer build
/// ships, but it must never put back what was removed or overwrite an edit.
@Test func aStoredLibraryKeepsEditsAndRemovalsAcrossLaunches() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RoleLibraryStore(fileURL: directory.appendingPathComponent("roles.json"))

    #expect(try store.load() == nil)  // nothing written yet

    var library = RoleLibrary.shipped
    let edited = try #require(library.targets.first)
    var rewritten = edited
    rewritten.systemPrompt = "Work the way this Mac's owner asked."
    rewritten.tags = ["Mine", " mine ", "local"]
    library.upsert(rewritten)
    let removed = try #require(library.targets.last)
    library.remove(id: removed.id)
    let written = library.add(name: "Release captain", text: "Cuts releases.", systemPrompt: "Ship it.")
    try store.save(library)

    let reloaded = try #require(try store.load())
    #expect(reloaded[id: rewritten.id]?.systemPrompt == "Work the way this Mac's owner asked.")
    // Tags are normalised once, on the way in, so a filter cannot miss one.
    #expect(reloaded[id: rewritten.id]?.tags == ["mine", "local"])
    #expect(reloaded[id: removed.id] == nil)
    #expect(reloaded.hiddenBuiltInIDs.contains(removed.id))
    #expect(reloaded[id: written.id]?.systemPrompt == "Ship it.")
    #expect(reloaded[id: written.id]?.isBuiltIn == false)

    // A library saved by an older build gains the roles a newer one ships.
    var partial = RoleLibrary(roles: [rewritten], hiddenBuiltInIDs: [removed.id])
    try store.save(partial)
    partial = try #require(try store.load())
    #expect(partial.roles.count == RoutingRole.builtInCatalog.count - 1)
    #expect(partial[id: removed.id] == nil)
    #expect(partial[id: rewritten.id]?.systemPrompt == "Work the way this Mac's owner asked.")
}

/// A role written before prompts and tags existed has to decode as the role it
/// was, not fail and take the whole library with it.
@Test func aRoleStoredBeforePromptsExistedStillReads() throws {
    let json = """
        {"id":"\(UUID().uuidString)","kind":"target","name":"Legacy",\
        "text":"Old wording.","effort":"high","isBuiltIn":false}
        """
    let role = try JSONDecoder().decode(RoutingRole.self, from: Data(json.utf8))

    #expect(role.name == "Legacy")
    #expect(role.systemPrompt == nil)
    #expect(role.modelPrompt == nil)
    #expect(role.tags.isEmpty)
    #expect(role.effort == .high)
}

// MARK: - Finding and shaping roles

/// The library is browsed, so a role has to be findable by anything the user
/// remembers about it — including a phrase from inside its prompt.
@Test func searchAndTagsFindARoleByEverythingItSays() throws {
    let library = RoleLibrary.shipped
    let debugger = try #require(library.targets.first { $0.name == "Debugger" })

    #expect(library.filtered(search: "debugger").contains { $0.id == debugger.id })
    #expect(library.filtered(search: "REPRODUCE").contains { $0.id == debugger.id })
    #expect(library.filtered(search: "flaky").contains { $0.id == debugger.id })
    #expect(library.filtered(tag: "debugging").contains { $0.id == debugger.id })
    #expect(library.filtered(search: "documentation", tag: "debugging").isEmpty)
    #expect(library.filtered(kind: .classifier).count == 1)
    #expect(library.filtered(search: "").count == library.roles.count)
    #expect(library.tags.contains("review"))
    #expect(library.tags == library.tags.sorted())
}

/// Duplicating is how a shipped role is taken as a starting point, so the copy
/// has to be a role of its own rather than a second window onto the original.
@Test func duplicatingAndResettingLeaveTheOriginalIntact() throws {
    var library = RoleLibrary.shipped
    let original = try #require(library.targets.first { $0.name == "Planner" })

    let duplicated = library.duplicate(id: original.id)
    let copy = try #require(duplicated)
    #expect(copy.id != original.id)
    #expect(copy.displayName == "Planner copy")
    #expect(copy.systemPrompt == original.systemPrompt)
    #expect(copy.isBuiltIn == false)
    #expect(library[id: original.id] == original)
    // The copy sits next to what it was copied from rather than at the end.
    #expect(library.roles.firstIndex { $0.id == copy.id }
        == library.roles.firstIndex { $0.id == original.id }.map { $0 + 1 })

    var edited = original
    edited.text = "Something else entirely."
    library.upsert(edited)
    #expect(library.isEdited(edited))
    let restored = library.resetToBuiltIn(id: original.id)
    #expect(restored == original)
    #expect(library[id: original.id] == original)
    #expect(!library.isEdited(original))
    #expect(!library.isEdited(copy))
}

// MARK: - The library and a setup

/// One role, two places it shows: the library it is written in, and the setup
/// holding a copy. An edit has to reach both, or a target drifts from the role
/// it says it holds.
@MainActor
@Test func editingALibraryRoleFollowsIntoTheSetupHoldingIt() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = modelWithLibrary(in: directory)
    await model.refreshSubscriptionModels()
    model.selectRoutingAlgorithm(.llmClassifier)

    let role = try #require(model.targetRoles.first)
    let target = try #require(model.profile.tiers.first { $0.roleID == role.id })
    var edited = role
    edited.name = "Everyday"
    edited.text = "Ordinary work."
    edited.systemPrompt = "Keep the change small."
    model.updateRole(edited)

    #expect(model.roleLibrary[id: role.id]?.systemPrompt == "Keep the change small.")
    let updated = try #require(model.profile.tiers.first { $0.id == target.id })
    #expect(updated.name == "Everyday")
    #expect(updated.summary == "Ordinary work.")
    #expect(model.roleLibraryError == nil)

    // …and it is on disk, not only in this window.
    let reloaded = try #require(
        try RoleLibraryStore(fileURL: directory.appendingPathComponent("roles.json")).load()
    )
    #expect(reloaded[id: role.id]?.name == "Everyday")
}

/// A role only reaches the generated configuration once a target holds it, and
/// then it has to carry both halves: the description the judge reads and the
/// prompt the model is sent.
@MainActor
@Test func aRoleTakenFromTheLibraryWritesItsPromptOntoItsTarget() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = modelWithLibrary(in: directory)
    await model.refreshSubscriptionModels()
    model.selectRoutingAlgorithm(.llmClassifier)

    let reviewer = try #require(model.roleLibrary.targets.first { $0.name == "Code reviewer" })
    #expect(!model.isRoleInSetup(reviewer))
    let target = try #require(model.profile.tiers.last)
    model.assignLibraryRole(reviewer.id, to: target.id)

    #expect(model.isRoleInSetup(reviewer))
    #expect(model.targetsHolding(reviewer).map(\.id) == [target.id])
    for index in model.profile.tiers.indices {
        model.profile.tiers[index].modelID = libraryModels[index % libraryModels.count].id
    }
    model.profile.classifierTargetID = model.profile.tiers.first?.id
    model.profile.defaultTargetID = model.profile.tiers.last?.id

    let toml = try SwitchyardConfigWriter.render(profile: model.profile)
    let document = try TOMLTable(string: toml)
    let name = try #require(model.profile.targetName(for: target.id))
    let written = try #require(document["targets"]?.table?[name]?.table)
    #expect(written["system_prompt"]?.string == reviewer.systemPrompt)
    #expect(written["reasoning_effort"]?.string == reviewer.effort?.rawValue)
    // The judge is told what the group is for, which is not what the model is told.
    #expect(toml.contains(reviewer.text.prefix(30)))
}

/// Native target options are the user's own words. A role must not overrule a
/// prompt already written there.
@Test func aTargetsOwnOptionsWinOverTheRolesPrompt() throws {
    var profile = classifierProfile()
    let role = RoutingRole(name: "Prompted", text: "Work.", systemPrompt: "From the role.", effort: .low)
    profile.roles.append(role)
    profile.assignRole(role.id, to: profile.tiers[0].id)
    profile.tiers[0].nativeOptions = "system_prompt = \"From the target.\"\n"

    let document = try TOMLTable(string: SwitchyardConfigWriter.render(profile: profile))
    let written = try #require(document["targets"]?.table?["prompted"]?.table)
    #expect(written["system_prompt"]?.string == "From the target.")
}

/// The routing step offers the judge's prompt to be read before a route runs,
/// so what it shows has to be the prompt the route will actually carry —
/// including the group list, which is the part nobody writes by hand.
@Test func theJudgePromptPreviewIsTheOneTheRouteCarries() throws {
    var profile = classifierProfile()
    let judged = RoutingRole(name: "Careful", text: "Work that has to be thought about.")
    profile.roles.append(judged)
    profile.assignRole(judged.id, to: profile.tiers[1].id)

    let preview = SwitchyardConfigWriter.judgePromptPreview(profile: profile)

    // Nothing is left for the reader to substitute in their head.
    #expect(!preview.contains(RoutingRole.targetsPlaceholder))
    #expect(!preview.contains(RoutingRole.targetNamesPlaceholder))
    #expect(preview.contains("- one: First."))
    #expect(preview.contains("- careful: Work that has to be thought about."))
    #expect(preview.contains(#"{"decision": {"target": "<one of: one, careful>"}}"#))
    // …and it is the same text the generated configuration hands the server.
    #expect(try SwitchyardConfigWriter.render(profile: profile).contains(preview))
}

/// The routing step asks one question about the judge — which model decides —
/// and both answers have to count. A judge on a model of its own is a complete
/// answer, not a setting on top of a target that also has to be chosen.
@Test func eitherAnswerAboutTheJudgeCompletesTheRoute() throws {
    var profile = classifierProfile()
    profile.classifierTargetID = nil
    profile.judgeModelID = nil

    let unanswered = profile.roleValidationErrors
    #expect(unanswered.contains { $0.hasPrefix("Choose which model decides the routing") })

    // Sharing a target's model.
    profile.classifierTargetID = profile.tiers[0].id
    #expect(profile.classifierModel == profile.tiers[0].assignedModel)
    #expect(!profile.roleValidationErrors.contains { $0.hasPrefix("Choose which model decides") })

    // Or a model of its own, with no target named at all.
    profile.classifierTargetID = nil
    profile.judgeModelID = libraryModels[1].id
    #expect(profile.classifierModel == libraryModels[1].id)
    #expect(!profile.roleValidationErrors.contains { $0.hasPrefix("Choose which model decides") })
    #expect(profile.judgeTargetName != nil)

    // The fallback is its own question, and stays required.
    profile.defaultTargetID = nil
    #expect(profile.roleValidationErrors.contains(
        "Choose the target that serves a turn the judge cannot place."
    ))
}

/// Removing a role must not quietly strip the wording from the targets that
/// held it: what the judge reads stays put, and the role simply stops being
/// offered.
@MainActor
@Test func removingARoleLeavesItsWordingOnTheTargetsThatHeldIt() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = modelWithLibrary(in: directory)
    await model.refreshSubscriptionModels()
    model.selectRoutingAlgorithm(.llmClassifier)

    let role = try #require(model.targetRoles.first)
    let target = try #require(model.profile.tiers.first { $0.roleID == role.id })
    model.removeRole(id: role.id)

    #expect(model.roleLibrary[id: role.id] == nil)
    #expect(!model.isRoleInSetup(role))
    let kept = try #require(model.profile.tiers.first { $0.id == target.id })
    #expect(kept.roleID == nil)
    #expect(kept.summary == role.text)
    #expect(kept.name == role.displayName)
}

/// An edited prompt can be kept for another setup. Saving it writes
/// a role every setup can then pick.
@MainActor
@Test func anEditedPromptCanBeKeptAsARole() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = modelWithLibrary(in: directory)

    let saved = model.addRole(named: "Everyday work", prompt: "Stay close to the diff.", tags: ["workflow"])

    #expect(saved.systemPrompt == "Stay close to the diff.")
    #expect(saved.tags == ["workflow"])
    // A built-in role already holds that name, so the kept one takes another.
    #expect(saved.displayName != "Efficient")
    #expect(model.roleLibrary[id: saved.id] != nil)
    #expect(!model.isRoleInSetup(saved))
    let reloaded = try #require(
        try RoleLibraryStore(fileURL: directory.appendingPathComponent("roles.json")).load()
    )
    #expect(reloaded[id: saved.id]?.systemPrompt == "Stay close to the diff.")
}

/// A role edited in one window is the role every later setup gets. A profile
/// built before the library was read must not keep serving the shipped wording
/// while this screen shows the user's own.
@MainActor
@Test func aLaterLaunchBuildsItsSetupFromTheEditedLibrary() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = modelWithLibrary(in: directory)
    await first.refreshSubscriptionModels()
    first.selectRoutingAlgorithm(.llmClassifier)
    let role = try #require(first.targetRoles.first)
    var edited = role
    edited.text = "Only the smallest edits."
    edited.systemPrompt = "Touch one file."
    first.updateRole(edited)

    let second = modelWithLibrary(in: directory)
    second.selectRoutingAlgorithm(.llmClassifier)

    #expect(second.roles[id: role.id]?.text == "Only the smallest edits.")
    #expect(second.roles[id: role.id]?.systemPrompt == "Touch one file.")
    let target = try #require(second.profile.tiers.first { $0.roleID == role.id })
    #expect(target.summary == "Only the smallest edits.")
}

/// A setup restored from disk may carry roles written before the library
/// existed. They belong in the library too, or the user can use them without
/// ever being able to find them.
@MainActor
@Test func aSetupsOwnRolesAreTakenIntoTheLibrary() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stored = RoutingRole(name: "From an older setup", text: "Whatever it did.", effort: .medium)
    var profile = classifierProfile()
    profile.roles.append(stored)
    let setup = SavedRoutingSetup(
        profile: profile, discoveredModels: libraryModels, binaryPathOverride: "", savedAt: Date()
    )
    let setupStore = SavedRoutingSetupStore(fileURL: directory.appendingPathComponent("setup.json"))
    try setupStore.save(setup)

    let model = WizardModel(
        routingConfigPath: directory.appendingPathComponent("routes.toml"),
        codexConfigPath: librarySetup.configPath,
        codexProfilePath: directory.appendingPathComponent("profile.toml"),
        sessionStore: ActiveRoutingSessionStore(fileURL: directory.appendingPathComponent("session.json")),
        savedSetupStore: setupStore,
        roleLibraryStore: RoleLibraryStore(fileURL: directory.appendingPathComponent("roles.json")),
        setupReader: LibrarySetupReader(),
        modelDiscovery: LibraryDiscovery(),
        cliVersionProbe: { "test" },
        restoreSavedSetup: true,
        diagnostics: DiagnosticLog(url: directory.appendingPathComponent("diagnostics.log"))
    )

    #expect(model.roleLibrary[id: stored.id]?.name == "From an older setup")
    #expect(model.isRoleInSetup(stored))
}
