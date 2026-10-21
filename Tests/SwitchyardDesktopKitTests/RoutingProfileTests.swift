import Foundation
import Testing
import TOMLKit
@testable import SwitchyardDesktopKit

private func stageProfile() -> RoutingProfile {
    RoutingProfile(
        provider: .codex,
        algorithm: .stageRouter,
        tiers: [
            TaskTier(name: "Efficient", summary: "Simple.", modelID: "gpt-5-mini"),
            TaskTier(name: "Capable", summary: "Complex.", modelID: "gpt-5-codex"),
        ]
    )
}

private func classifierProfile() -> RoutingProfile {
    let targets = [
        TaskTier(name: "Fast", summary: "Simple.", modelID: "gpt-5-mini"),
        TaskTier(name: "Deep", summary: "Complex.", modelID: "gpt-5-codex"),
    ]
    return RoutingProfile(
        provider: .codex,
        algorithm: .llmClassifier,
        tiers: targets,
        classifierTargetID: targets[0].id,
        defaultTargetID: targets[1].id
    )
}

@Test func codableRoundTripPreservesEveryField() throws {
    let original = classifierProfile()
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(RoutingProfile.self, from: data)
    #expect(decoded == original)
    #expect(decoded.algorithm == .llmClassifier)
    #expect(decoded.classifierTargetName == "fast")
    #expect(decoded.defaultTargetName == "deep")
}

@Test(arguments: [false, true])
func savedNativeSummaryPreferenceMigratesToTheClient(_ enabled: Bool) throws {
    var original = stageProfile()
    original.nativeRouteOptions = """
    reasoning_summaries = \(enabled)
    type = "stage_router"
    capable_target = "capable"
    efficient_target = "efficient"
    [routes.main.handoff_notes]
    escalation_note = "Keep reasoning_summaries = false inside this prompt."
    """
    let decoded = try JSONDecoder().decode(RoutingProfile.self, from: JSONEncoder().encode(original))
    #expect(decoded.advertisesReasoningSummaries == enabled)
    let document = try TOMLTable(string: SwitchyardConfigWriter.render(profile: decoded))
    let route = try #require(document["routes"]?.table?["main"]?.table)
    #expect(route["reasoning_summaries"] == nil)
    #expect(route["handoff_notes"]?.table?["escalation_note"]?.string ==
        "Keep reasoning_summaries = false inside this prompt.")
}

@Test func aNewProfileRequiresExplicitAlgorithmSelection() {
    let profile = RoutingProfile()
    #expect(profile.algorithm == nil)
    #expect(profile.tiers.isEmpty)
    #expect(profile.roleValidationErrors == ["Choose a routing algorithm."])
    #expect(!profile.isValid)
}

@Test func stageRouterHasExactlyEfficientAndCapableRoles() {
    var profile = RoutingProfile()
    profile.selectAlgorithm(.stageRouter)

    #expect(profile.algorithm == .stageRouter)
    #expect(profile.tiers.map(\.displayName) == ["Efficient", "Capable"])
    #expect(profile.targetNames == ["efficient", "capable"])
    #expect(profile.unassignedTiers.count == 2)
    #expect(!profile.canAddTier)
    #expect(!profile.canRemoveTier)
}

@Test func classifierRequiresTwoToSixTargetsAndExplicitSelections() {
    var profile = RoutingProfile()
    profile.selectAlgorithm(.llmClassifier)

    #expect(profile.tiers.count == TaskTier.minimumCount)
    #expect(profile.roleValidationErrors.contains {
        $0.hasPrefix("Choose which model decides the routing")
    })
    #expect(profile.roleValidationErrors.contains(
        "Choose the target that serves a turn the judge cannot place."
    ))

    for index in profile.tiers.indices {
        profile.tiers[index].modelID = "model-\(index)"
        profile.tiers[index].summary = "Work for target \(index + 1)."
    }
    profile.classifierTargetID = profile.tiers[0].id
    profile.defaultTargetID = profile.tiers[1].id
    #expect(profile.isValid)

    while profile.canAddTier { profile.addTier() }
    #expect(profile.tiers.count == TaskTier.maximumCount)
    // Added targets take the next free role and its name; past the built-in
    // ladder they fall back to a numbered target of their own.
    #expect(Set(profile.tiers.map(\.displayName)).count == profile.tiers.count)
    #expect(profile.tiers.suffix(2).allSatisfy { $0.displayName.hasPrefix("Target ") })
    profile.addTier()
    #expect(profile.tiers.count == TaskTier.maximumCount)

    while profile.canRemoveTier { profile.removeTier(id: profile.tiers.last!.id) }
    #expect(profile.tiers.count == TaskTier.minimumCount)
}

/// The judge reads only these descriptions, so an undescribed role would make
/// every turn fall through to the default target and the route would serve one
/// model. Applying such a setup has to be blocked, including the instructional
/// text older builds pre-filled and saved.
@Test func classifierTargetsMustBeDescribedBeforeApplying() {
    var profile = classifierProfile()
    #expect(profile.isValid)

    profile.tiers[1].summary = "   "
    #expect(profile.undescribedTiers.map(\.displayName) == ["Deep"])
    #expect(!profile.isValid)
    #expect(profile.roleValidationErrors.contains { $0.contains("Deep") })

    for placeholder in TaskTier.legacySummaryPlaceholders {
        profile.tiers[1].summary = placeholder
        #expect(!profile.isValid)
    }

    profile.tiers[1].summary = "Cross-module refactors and hard debugging."
    #expect(profile.isValid)
}

/// Stage routing ships real role descriptions and hands none to a judge, so the
/// rule above must never block it.
@Test func stageRoutingIsNeverBlockedOnDescriptions() {
    var profile = stageProfile()
    profile.tiers[0].summary = ""
    #expect(profile.undescribedTiers.isEmpty)
    #expect(profile.isValid)
}

@Test func changingAlgorithmClearsIncompatibleAssignmentsAndClassifierChoices() {
    var profile = classifierProfile()
    profile.selectAlgorithm(.stageRouter)

    #expect(profile.tiers.map(\.displayName) == ["Efficient", "Capable"])
    #expect(profile.unassignedTiers.count == 2)
    #expect(profile.classifierTargetID == nil)
    #expect(profile.defaultTargetID == nil)

    profile.selectAlgorithm(.llmClassifier)
    #expect(profile.tiers.count == 2)
    #expect(profile.unassignedTiers.count == 2)
    #expect(profile.classifierTargetID == nil)
    #expect(profile.defaultTargetID == nil)
}

@Test func classifierTargetChoicesMustReferToExistingTargets() {
    var profile = classifierProfile()
    profile.classifierTargetID = UUID()
    profile.defaultTargetID = UUID()

    #expect(profile.classifierTargetName == nil)
    #expect(profile.defaultTargetName == nil)
    #expect(!profile.isValid)
}

@Test func profileWithEveryStageRoleAssignedIsValid() {
    let profile = stageProfile()
    #expect(profile.unassignedTiers.isEmpty)
    #expect(profile.isValid)
    #expect(profile.validationErrors.isEmpty)
}

@Test func emptyModelIDCountsAsUnassigned() {
    var profile = stageProfile()
    profile.tiers[0].modelID = ""
    #expect(profile.tiers[0].assignedModel == nil)
    #expect(!profile.isValid)
}

@Test func clearingAModelEmptiesEveryRoleUsingIt() {
    var profile = stageProfile()
    profile.tiers[1].modelID = "gpt-5-mini"
    profile.clearAssignments(of: "gpt-5-mini")
    #expect(profile.unassignedTiers.count == 2)
}

@Test func reservedPortIsRejected() {
    var profile = stageProfile()
    profile.port = RoutingProfile.reservedPort
    #expect(!profile.isValid)
    #expect(profile.validationErrors.contains { $0.contains("4000") })
}

@Test func defaultsUseLoopbackOnPort4100() {
    let profile = RoutingProfile()
    #expect(profile.host == "127.0.0.1")
    #expect(profile.port == 4100)
    #expect(profile.port != RoutingProfile.reservedPort)
    #expect(profile.proxyBaseURL == "http://127.0.0.1:4100/v1")
}

@Test func upstreamBaseURLDefaultsToTheProviderAPIAndMustBeAbsolute() {
    var profile = stageProfile()
    #expect(profile.upstreamBaseURL == "http://127.0.0.1:4101/v1")
    #expect(profile.usesManagedLiteLLM)
    #expect(!profile.forwardsCallerCredential)

    profile.upstreamBaseURL = "not a url"
    #expect(!profile.isValid)

    profile.upstreamBaseURL = "http://127.0.0.1:4001/v1"
    #expect(profile.isValid)
    #expect(!profile.usesManagedLiteLLM)
    #expect(!profile.forwardsCallerCredential)

    profile.upstreamBaseURL = "https://chatgpt.com/backend-api/codex"
    #expect(profile.forwardsCallerCredential)
}

@Test func decodingALegacyClassifierProfileMakesSelectionsExplicit() throws {
    let legacy = """
    {"provider":"codex",
     "tiers":[{"id":"9E1B7A6C-0000-4000-8000-000000000001","name":"Fast","summary":"s","modelID":"a"},
              {"id":"9E1B7A6C-0000-4000-8000-000000000002","name":"Balanced","summary":"s","modelID":"b"},
              {"id":"9E1B7A6C-0000-4000-8000-000000000003","name":"Deep","summary":"s","modelID":"c"}],
     "host":"127.0.0.1","port":4100,"routeID":"switchyard-desktop"}
    """
    let decoded = try JSONDecoder().decode(RoutingProfile.self, from: Data(legacy.utf8))
    #expect(decoded.algorithm == .llmClassifier)
    #expect(decoded.classifierTargetName == "balanced")
    #expect(decoded.defaultTargetName == "deep")
    #expect(decoded.upstreamBaseURL == Provider.codex.defaultUpstreamBaseURL)
}

@Test func unsupportedProviderIsInvalid() {
    var profile = stageProfile()
    profile.provider = .anthropic
    #expect(!profile.isValid)
}

// MARK: - Judge upstream

@Test func onlyADirectClassifierSendsItsJudgeThroughLiteLLM() {
    var profile = classifierProfile()
    // The bundled LiteLLM already serves every turn, judge included.
    #expect(!profile.routesJudgeThroughLiteLLM)
    #expect(profile.needsManagedLiteLLM)
    #expect(profile.managedLiteLLMModels == ["gpt-5-mini", "gpt-5-codex"])

    profile.upstreamBaseURL = "https://chatgpt.com/backend-api/codex"
    #expect(profile.routesJudgeThroughLiteLLM)
    #expect(profile.needsManagedLiteLLM)
    // Only the judge's own model has to be served locally.
    #expect(profile.managedLiteLLMModels == [LiteLLMModel("judge-gpt-5-mini", servedBy: "gpt-5-mini")])
    #expect(profile.judgeTargetName == "judge")

    // A stage router makes no judge call at all.
    var stage = stageProfile()
    stage.upstreamBaseURL = "https://chatgpt.com/backend-api/codex"
    #expect(!stage.routesJudgeThroughLiteLLM)
    #expect(!stage.needsManagedLiteLLM)
    #expect(stage.managedLiteLLMModels == nil)
    #expect(stage.judgeTargetName == nil)

    // An independently managed loopback upstream owns its own request shaping.
    var external = classifierProfile()
    external.upstreamBaseURL = "http://127.0.0.1:4001/v1"
    #expect(!external.routesJudgeThroughLiteLLM)
    #expect(!external.needsManagedLiteLLM)
    #expect(external.managedLiteLLMModels == nil)
}

@Test func anUnassignedClassifierTargetNeedsNoJudgeClient() {
    var profile = classifierProfile()
    profile.upstreamBaseURL = "https://chatgpt.com/backend-api/codex"
    profile.tiers[0].modelID = nil

    #expect(profile.classifierModel == nil)
    #expect(!profile.routesJudgeThroughLiteLLM)
    #expect(profile.judgeTargetName == nil)
}

// MARK: - Route context window

private func windowProfile(
    models: [String],
    windows: [String: Int],
    judge: String? = nil
) -> RoutingProfile {
    let targets = models.enumerated().map { index, id in
        TaskTier(name: "Tier \(index + 1)", summary: "Work.", modelID: id)
    }
    var profile = RoutingProfile(
        provider: .codex,
        algorithm: .llmClassifier,
        tiers: targets,
        classifierTargetID: targets.first?.id,
        defaultTargetID: targets.last?.id
    )
    profile.modelContextWindows = windows
    profile.judgeModelID = judge
    return profile
}

/// Codex measures one window against a whole conversation while any turn may
/// go to any target, so only the smallest is safe for every turn.
@Test func theRouteWindowIsTheSmallestEveryTargetAccepts() {
    let profile = windowProfile(
        models: ["gpt-5.6-sol", "gpt-5.5"],
        windows: ["gpt-5.6-sol": 872_000, "gpt-5.5": 272_000]
    )

    #expect(profile.routeContextWindow == 272_000)
}

@Test func theRouteWindowRisesWhenEveryTargetAgrees() {
    let profile = windowProfile(
        models: ["gpt-5.6-luna", "gpt-6-astra"],
        windows: ["gpt-5.6-luna": 872_000, "gpt-6-astra": 872_000]
    )

    #expect(profile.routeContextWindow == 872_000)
    #expect(profile.contextWindowCappingModels.isEmpty)
}

/// An unknown target makes the smallest window unknown, and advertising the
/// rest would promise Codex more than that target can serve.
@Test func anUndiscoveredTargetLeavesTheRouteWithoutAWindow() {
    let profile = windowProfile(
        models: ["gpt-5.6-sol", "mystery-model"],
        windows: ["gpt-5.6-sol": 872_000]
    )

    #expect(profile.routeContextWindow == nil)
}

@Test func anUnassignedTargetLeavesTheRouteWithoutAWindow() {
    var profile = windowProfile(
        models: ["gpt-5.6-sol", "gpt-5.5"],
        windows: ["gpt-5.6-sol": 872_000, "gpt-5.5": 272_000]
    )
    profile.tiers[1].modelID = nil

    #expect(profile.routeContextWindow == nil)
}

/// The judge writes its own short prompt and is never a destination for the
/// conversation Codex measures, so it does not hold the route down.
@Test func theJudgeDoesNotCapTheRouteWindow() {
    var profile = windowProfile(
        models: ["gpt-5.6-sol", "gpt-6-astra"],
        windows: ["gpt-5.6-sol": 872_000, "gpt-6-astra": 872_000, "gpt-5.2": 272_000],
        judge: "gpt-5.2"
    )
    profile.judgeModelID = "gpt-5.2"

    #expect(profile.routeContextWindow == 872_000)
}

@Test func namesTheTargetsHoldingTheWindowDown() {
    let profile = windowProfile(
        models: ["gpt-5.6-sol", "gpt-5.5", "gpt-5.2"],
        windows: ["gpt-5.6-sol": 872_000, "gpt-5.5": 272_000, "gpt-5.2": 272_000]
    )

    #expect(profile.contextWindowCappingModels == ["gpt-5.5", "gpt-5.2"])
}

// MARK: - Long context

/// OpenAI bills a prompt over 272k tokens at a premium, so with long context off
/// the route stops at the standard window however much the models accept.
@Test func longContextOffHoldsTheRouteAtTheStandardWindow() {
    var profile = windowProfile(
        models: ["gpt-5.6-luna", "gpt-6-astra"],
        windows: ["gpt-5.6-luna": 872_000, "gpt-6-astra": 872_000]
    )
    profile.allowsLongContext = false

    #expect(profile.routeContextWindow == 272_000)
    #expect(profile.longContextIsBlocked)
    // The setting sets the window, not any one model, so none is named.
    #expect(profile.contextWindowCappingModels.isEmpty)
}

@Test func longContextOnAdvertisesTheFullWindow() {
    let profile = windowProfile(
        models: ["gpt-5.6-luna", "gpt-6-astra"],
        windows: ["gpt-5.6-luna": 872_000, "gpt-6-astra": 872_000]
    )

    #expect(profile.allowsLongContext)
    #expect(profile.routeContextWindow == 872_000)
    #expect(!profile.longContextIsBlocked)
}

/// A window already at or under the standard size is never raised or blamed on
/// the setting.
@Test func longContextOffLeavesASmallerWindowAlone() {
    var profile = windowProfile(
        models: ["gpt-5.6-sol", "gpt-5.5"],
        windows: ["gpt-5.6-sol": 872_000, "gpt-5.5": 200_000]
    )
    profile.allowsLongContext = false

    #expect(profile.routeContextWindow == 200_000)
    #expect(!profile.longContextIsBlocked)
    #expect(profile.contextWindowCappingModels == ["gpt-5.5"])
}

/// Without a discovered window Codex keeps its own 272k default, which is
/// already the standard size.
@Test func longContextOffDoesNotInventAWindow() {
    var profile = windowProfile(models: ["gpt-5.6-sol", "mystery-model"], windows: ["gpt-5.6-sol": 872_000])
    profile.allowsLongContext = false

    #expect(profile.routeContextWindow == nil)
    #expect(!profile.longContextIsBlocked)
}

@Test func longContextSettingRoundTripsAndDefaultsOnForOlderProfiles() throws {
    var profile = windowProfile(models: ["gpt-5.6-sol", "gpt-5.5"], windows: [:])
    profile.allowsLongContext = false
    let data = try JSONEncoder().encode(profile)
    #expect(try JSONDecoder().decode(RoutingProfile.self, from: data).allowsLongContext == false)

    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "allowsLongContext")
    let legacy = try JSONSerialization.data(withJSONObject: object)
    #expect(try JSONDecoder().decode(RoutingProfile.self, from: legacy).allowsLongContext)
}

// MARK: - Roles

private func roleProfile() -> RoutingProfile {
    RoutingProfile(provider: .codex, algorithm: .llmClassifier)
}

/// A fresh classifier starts on the built-in ladder rather than on blank fields
/// nothing forces the user to fill.
@Test func aFreshClassifierStartsOnTheBuiltInRoles() {
    let profile = roleProfile()

    #expect(profile.classifierRole?.kind == .classifier)
    #expect(profile.tiers.allSatisfy { $0.roleID != nil })
    #expect(profile.undescribedTiers.isEmpty)
}

/// Stage routing's two roles are fixed by the server, so a role must not rename
/// them out from under it.
@Test func stageRoutingKeepsItsOwnFixedRoleNames() {
    let profile = RoutingProfile(provider: .codex, algorithm: .stageRouter)

    #expect(profile.tiers.map(\.displayName) == ["Efficient", "Capable"])
    #expect(profile.tiers.allSatisfy { $0.roleID == nil })
}

@Test func assigningARoleGivesTheTargetItsWording() {
    var profile = roleProfile()
    let role = try! #require(profile.roles.targets.last)

    profile.assignRole(role.id, to: profile.tiers[0].id)

    #expect(profile.tiers[0].displayName == role.displayName)
    #expect(profile.tiers[0].summary == role.text)
}

/// The point of a role: one edit, every target holding it.
@Test func editingARoleReachesEveryTargetHoldingIt() {
    var profile = roleProfile()
    let role = try! #require(profile.roles.targets.first)
    profile.assignRole(role.id, to: profile.tiers[0].id)
    profile.assignRole(role.id, to: profile.tiers[1].id)

    profile.updateRole(RoutingRole(id: role.id, name: "Renamed", text: "Rewritten.", effort: .max))

    #expect(profile.tiers.map(\.summary) == ["Rewritten.", "Rewritten."])
    #expect(profile.tiers.allSatisfy { profile.effort(of: $0) == .max })
}

/// Removing a role must not take a target's description with it.
@Test func removingARoleLeavesItsWordingOnTheTarget() {
    var profile = roleProfile()
    let role = try! #require(profile.roles.targets.first)
    profile.assignRole(role.id, to: profile.tiers[0].id)
    let inherited = profile.tiers[0].summary

    profile.removeRole(id: role.id)

    #expect(profile.tiers[0].roleID == nil)
    #expect(profile.tiers[0].summary == inherited)
    #expect(profile.roles[id: role.id] == nil)
}

/// The judge would otherwise be asked to choose between groups it was never
/// shown, and every turn would fall through to the default target.
@Test func aClassifierPromptMissingItsMarkerIsRejected() {
    var profile = roleProfile()
    profile.tiers[0].modelID = "gpt-fast"
    profile.tiers[1].modelID = "gpt-strong"
    profile.classifierTargetID = profile.tiers[0].id
    profile.defaultTargetID = profile.tiers[1].id
    #expect(profile.roleValidationErrors.isEmpty)

    var classifier = try! #require(profile.classifierRole)
    classifier.text = "Just pick one."
    profile.updateRole(classifier)

    #expect(profile.roleValidationErrors.contains { $0.contains(RoutingRole.targetsPlaceholder) })
}

/// A profile saved before roles existed carries its wording on the targets. The
/// built-ins must not be offered over the top of it.
@Test func decodingAProfileWithoutRolesLiftsItsOwnWording() throws {
    let tiers = [
        TaskTier(name: "Fast", summary: "Small edits.", modelID: "gpt-fast"),
        TaskTier(name: "Deep", summary: "Hard problems.", modelID: "gpt-strong"),
    ]
    var legacy = RoutingProfile(
        provider: .codex, algorithm: .llmClassifier, tiers: tiers,
        classifierTargetID: tiers[0].id, defaultTargetID: tiers[1].id
    )
    legacy.roles = []
    let data = try JSONEncoder().encode(legacy)

    let decoded = try JSONDecoder().decode(RoutingProfile.self, from: data)

    #expect(decoded.roles.targets.map(\.text) == ["Small edits.", "Hard problems."])
    #expect(decoded.tiers.map(\.summary) == ["Small edits.", "Hard problems."])
    #expect(decoded.classifierRole != nil)
    // Lifting the same saved profile twice has to give the same roles.
    #expect(try JSONDecoder().decode(RoutingProfile.self, from: data) == decoded)
}

/// Switchyard keeps one target per model id and rejects the whole file when two
/// name the same model but ask for different things. Roles reach that in one
/// click, so the wizard has to say it before the dry run does.
@Test func twoTargetsOnOneModelUnderDifferentRolesIsRejected() {
    var profile = roleProfile()
    profile.tiers[0].modelID = "gpt-5.6-sol"
    profile.tiers[1].modelID = "gpt-5.6-sol"
    profile.classifierTargetID = profile.tiers[0].id
    profile.defaultTargetID = profile.tiers[1].id

    #expect(profile.conflictingDuplicateModels == ["gpt-5.6-sol"])
    #expect(profile.roleValidationErrors.contains { $0.contains("gpt-5.6-sol") })

    // The same role on both asks for the same thing, which the server keeps.
    let shared = try! #require(profile.roles.targets.first)
    profile.assignRole(shared.id, to: profile.tiers[0].id)
    profile.assignRole(shared.id, to: profile.tiers[1].id)

    #expect(profile.conflictingDuplicateModels.isEmpty)
}

/// The wizard reaches a classifier by picking the algorithm, not by building a
/// profile — so that path has to arrive on the roles too.
@Test func choosingClassifierRoutingPutsItsTargetsOnRoles() {
    var profile = RoutingProfile(provider: .codex)

    profile.selectAlgorithm(.llmClassifier)

    #expect(profile.tiers.allSatisfy { profile.role(of: $0) != nil })
    #expect(profile.undescribedTiers.isEmpty)
    #expect(profile.tiers.map(\.displayName) == ["Direct", "Standard"])
}

@Test func anAddedTargetTakesTheNextRoleNothingHoldsYet() {
    var profile = RoutingProfile(provider: .codex, algorithm: .llmClassifier)

    profile.addTier()

    #expect(profile.tiers.count == 3)
    #expect(profile.tiers[2].displayName == "Investigative")
    #expect(profile.undescribedTiers.isEmpty)
}

/// Stage routing has no roles, and choosing it must not rename its two.
@Test func choosingStageRoutingKeepsEfficientAndCapable() {
    var profile = RoutingProfile(provider: .codex, algorithm: .llmClassifier)

    profile.selectAlgorithm(.stageRouter)

    #expect(profile.tiers.map(\.displayName) == ["Efficient", "Capable"])
}
