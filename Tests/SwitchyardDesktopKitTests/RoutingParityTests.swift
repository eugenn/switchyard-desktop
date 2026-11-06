import Foundation
import Testing
import TOMLKit
@testable import SwitchyardDesktopKit

private func parityProfile(_ algorithm: RoutingAlgorithm = .llmClassifier) -> RoutingProfile {
    var profile = RoutingProfile(algorithm: algorithm)
    for index in profile.tiers.indices {
        profile.tiers[index].modelID = "model-\(index)"
        profile.tiers[index].summary = "Work for role \(index)."
    }
    profile.classifierTargetID = profile.tiers.first?.id
    profile.defaultTargetID = profile.tiers.last?.id
    return profile
}

@Test func classifierUsesSwitchyardRequestCadenceAndVerdictBudget() throws {
    let document = try TOMLTable(string: SwitchyardConfigWriter.render(profile: parityProfile()))
    let route = try #require(document["routes"]?.table?["main"]?.table)
    #expect(route["classify_trigger"]?.string == "every_request")
    // Omission delegates the 4096-token default to Switchyard.
    #expect(route["max_output_tokens"] == nil)
    #expect(route["recent_turn_window"] == nil)
}

@Test(arguments: [RoutingAlgorithm.capability, .escalation, .composite, .advisor])
func nativeJudgesUsePackagedPrompts(_ algorithm: RoutingAlgorithm) throws {
    let profile = parityProfile(algorithm)
    let document = try TOMLTable(string: SwitchyardConfigWriter.render(profile: profile))
    let route = try #require(document["routes"]?.table?["main"]?.table)
    #expect(route["prompt"] == nil)
    #expect(route["reviewer_system_prompt"] == nil)
    #expect(route["classifier"]?.table?["prompt"] == nil)
    #expect(route["max_output_tokens"] == nil)
}

@Test func nativeOptionsSurvivePersistenceAndReplaceTheWholeAlgorithmBody() throws {
    var profile = parityProfile(.stageRouter)
    profile.nativeRouteOptions = """
    type = "stage_router"
    capable_target = "capable"
    efficient_target = "efficient"
    picker = "capable_first"
    confidence_threshold = 0.85
    recent_turn_window = 9
    [routes.main.tool_semantics]
    observe = ["lookup_customer"]
    mutate = ["update_inventory"]
    [routes.main.handoff_notes]
    escalation_note = "Diagnose the failure."
    [routes.main.subagents]
    type = "passthrough"
    target = "efficient"
    """
    profile.tiers[1].nativeOptions = """
    system_prompt = "Diagnose first.\\nThen act."
    reasoning_effort = "high"
    extra_body = { custom_option = "preserved" }
    """
    let restored = try JSONDecoder().decode(RoutingProfile.self, from: JSONEncoder().encode(profile))
    #expect(restored == profile)
    let text = try SwitchyardConfigWriter.render(profile: restored)
    #expect(text.contains(try #require(profile.nativeRouteOptions)))
    #expect(!text.contains("efficient_first"))
    let document = try TOMLTable(string: text)
    #expect(document["targets"]?.table?["capable"]?.table?["system_prompt"]?.string == "Diagnose first.\nThen act.")
}

@Test func nativeOptionsCannotReplaceTheAppOwnedClientOrModelIdentity() {
    var profile = parityProfile(.capability)
    profile.nativeRouteOptions = "type = \"llm_classifier\"\n[llm_clients.injected]\nbase_url = \"http://example.com\""
    #expect(!profile.isValid)
    profile.nativeRouteOptions = nil
    profile.tiers[0].nativeOptions = "id = \"different-model\""
    #expect(!profile.isValid)
}

@Test func separateJudgeIsIncludedInTheManagedGatewayAndSavedSetup() throws {
    var profile = parityProfile(.capability)
    profile.classifierTargetID = nil
    profile.judgeModelID = "separate-judge"
    profile.judgeNativeOptions = "reasoning_effort = \"low\""
    #expect(profile.isValid)
    #expect(profile.managedLiteLLMModels == ["model-0", "model-1", "separate-judge"])
    let document = try TOMLTable(string: SwitchyardConfigWriter.render(profile: profile))
    #expect(document["targets"]?.table?["judge"]?.table?["id"]?.string == "separate-judge")
    #expect(document["targets"]?.table?["judge"]?.table?["reasoning_effort"]?.string == "low")
    #expect(document["routes"]?.table?["main"]?.table?["classifier_target"]?.string == "judge")
}

@Test(arguments: RoutingAlgorithm.allCases.filter { $0 != .prefillRouter })
func generatedRouteMigrationPreservesNativePolicyAndPrompts(_ algorithm: RoutingAlgorithm) throws {
    var profile = parityProfile(algorithm)
    profile.judgeModelID = algorithm.requiresJudge ? "separate-judge" : nil
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("routes.toml")
    try SwitchyardConfigWriter.write(profile: profile, to: path)
    let restored = try SavedRoutingSetup.migrateGeneratedConfig(from: path)
    #expect(restored.profile.algorithm?.serverType == algorithm.serverType)
    let before = try TOMLTable(string: String(contentsOf: path, encoding: .utf8))
    let after = try TOMLTable(string: SwitchyardConfigWriter.render(profile: restored.profile))
    #expect(before["routes"]?.table?.convert(to: .json) == after["routes"]?.table?.convert(to: .json))
}

/// The integration harness calls this with a loopback mock upstream. Each file
/// comes from the production Swift writer and is validated by the bundled helper.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SWITCHYARD_DESKTOP_PARITY_FIXTURES"] != nil))
func nativeRoutingFixtures() throws {
    let environment = ProcessInfo.processInfo.environment
    let directory = URL(fileURLWithPath: try #require(environment["SWITCHYARD_DESKTOP_PARITY_FIXTURES"]))
    let binary = URL(fileURLWithPath: try #require(environment["SWITCHYARD_DESKTOP_TEST_SERVER"]))
    for algorithm in RoutingAlgorithm.allCases where algorithm != .prefillRouter {
        var profile = parityProfile(algorithm)
        profile.upstreamBaseURL = try #require(environment["SWITCHYARD_DESKTOP_PARITY_UPSTREAM"])
        profile.judgeModelID = algorithm.requiresJudge ? "judge-model" : nil
        // Models are deliberately distinct so selecting a tier is observable.
        if algorithm == .advisor { profile.classifierTargetID = profile.tiers.last?.id }
        let path = directory.appendingPathComponent("\(algorithm.rawValue).toml")
        try SwitchyardConfigWriter.write(profile: profile, to: path)
        try SwitchyardConfigWriter.validate(configPath: path, binaryPath: binary)
    }
    for variant in ["stage-classifier", "stage-subagents", "stage-target-prompts"] {
        var profile = parityProfile(.stageRouter)
        profile.upstreamBaseURL = try #require(environment["SWITCHYARD_DESKTOP_PARITY_UPSTREAM"])
        if variant == "stage-classifier" {
            profile.judgeModelID = "judge-model"
            profile.nativeRouteOptions = SwitchyardConfigWriter.defaultRouteOptions(profile: profile)
                + "\n[routes.main.classifier]\ntarget = \"judge\"\nbase_threshold = 0.5\n"
        } else if variant == "stage-subagents" {
            profile.additionalTargets = [TaskTier(name: "Worker", summary: "", modelID: "worker-model")]
            profile.nativeRouteOptions = SwitchyardConfigWriter.defaultRouteOptions(profile: profile)
                + "\n[routes.main.subagents]\ntype = \"passthrough\"\ntarget = \"worker\"\n"
        } else {
            profile.tiers[0].nativeOptions = "system_prompt = \"Efficient target: follow the settled plan.\""
            profile.tiers[1].nativeOptions = "system_prompt = \"Capable target: diagnose before editing.\""
        }
        let path = directory.appendingPathComponent("\(variant).toml")
        try SwitchyardConfigWriter.write(profile: profile, to: path)
        try SwitchyardConfigWriter.validate(configPath: path, binaryPath: binary)
    }
    // One provider model, two target identities: verify settings on the wire.
    for algorithm in [RoutingAlgorithm.stageRouter, .vgr] {
        var shared = parityProfile(algorithm)
        shared.upstreamBaseURL = try #require(environment["SWITCHYARD_DESKTOP_PARITY_UPSTREAM"])
        shared.tiers[0].modelID = "shared-model"
        shared.tiers[1].modelID = "shared-model"
        shared.tiers[0].nativeOptions = "reasoning_effort = \"low\"\nsystem_prompt = \"Efficient role.\""
        shared.tiers[1].nativeOptions = "reasoning_effort = \"high\"\nsystem_prompt = \"Capable role.\""
        if algorithm == .vgr {
            // VGR also uses these targets for judging; serving-only prompts
            // cannot be attached to a routing-only target.
            shared.tiers[0].nativeOptions = "reasoning_effort = \"low\""
            shared.tiers[1].nativeOptions = "reasoning_effort = \"high\""
        }
        let path = directory.appendingPathComponent("\(algorithm.rawValue)-shared-model.toml")
        try SwitchyardConfigWriter.write(profile: shared, to: path)
        try SwitchyardConfigWriter.validate(configPath: path, binaryPath: binary)
    }
    // Plan/Execute uses Stage tool semantics, passed through the app's
    // complete route body and trigger execution on a custom mutation tool.
    var planExecute = parityProfile(.planExecute)
    planExecute.upstreamBaseURL = try #require(environment["SWITCHYARD_DESKTOP_PARITY_UPSTREAM"])
    planExecute.nativeRouteOptions = SwitchyardConfigWriter.defaultRouteOptions(profile: planExecute)
        + "\n[routes.main.tool_semantics]\nmutate = [\"update_inventory\"]\n"
    let planExecutePath = directory.appendingPathComponent("plan-execute-custom-tool.toml")
    try SwitchyardConfigWriter.write(profile: planExecute, to: planExecutePath)
    try SwitchyardConfigWriter.validate(configPath: planExecutePath, binaryPath: binary)
    for trigger in ClassifyTrigger.allCases {
        var profile = parityProfile(.llmClassifier)
        profile.upstreamBaseURL = try #require(environment["SWITCHYARD_DESKTOP_PARITY_UPSTREAM"])
        profile.classifyTrigger = trigger
        profile.judgeModelID = "judge-model"
        let path = directory.appendingPathComponent("custom-\(trigger.rawValue).toml")
        try SwitchyardConfigWriter.write(profile: profile, to: path)
        try SwitchyardConfigWriter.validate(configPath: path, binaryPath: binary)
    }
}

@Test func noOpDoesNotStartTheManagedGateway() {
    let profile = RoutingProfile(algorithm: .noop)
    #expect(profile.isValid)
    #expect(!profile.needsManagedLiteLLM)
    #expect(profile.managedLiteLLMModels == nil)
}

@Test func verificationGatedRoutingStartsInShadowModeWithDistinctTargets() throws {
    var profile = parityProfile(.vgr)
    let document = try TOMLTable(string: SwitchyardConfigWriter.render(profile: profile))
    let route = try #require(document["routes"]?.table?["main"]?.table)
    #expect(route["type"]?.string == "vgr")
    #expect(route["mode"]?.string == "shadow")
    #expect(route["active_approval"] == nil)
    #expect(route["efficient_target"]?.string == "efficient")
    #expect(route["capable_target"]?.string == "capable")
    profile.tiers[1].modelID = profile.tiers[0].modelID
    #expect(profile.isValid)
}

@Test func verificationGatedJudgesSurviveMigrationAndRequireExistingTargets() throws {
    var profile = parityProfile(.vgr)
    profile.judgeModelID = "separate-judge"
    profile.nativeRouteOptions = SwitchyardConfigWriter.defaultRouteOptions(profile: profile)
        + "judge_target = \"judge\"\ncapable_judge_target = \"capable\"\n"
    #expect(profile.isValid)
    let directory = UserDataLocations.testSandbox.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("routes.toml")
    try SwitchyardConfigWriter.write(profile: profile, to: path)
    let restored = try SavedRoutingSetup.migrateGeneratedConfig(from: path)
    #expect(restored.isUsable)
    #expect(restored.profile.judgeModelID == "separate-judge")
    let before = try TOMLTable(string: SwitchyardConfigWriter.render(profile: profile))
    let after = try TOMLTable(string: SwitchyardConfigWriter.render(profile: restored.profile))
    #expect(before["routes"]?.table?.convert(to: .json) == after["routes"]?.table?.convert(to: .json))
    for key in ["judge_target", "capable_judge_target"] {
        profile.nativeRouteOptions = SwitchyardConfigWriter.defaultRouteOptions(profile: profile)
            + "\(key) = \"missing\"\n"
        #expect(!profile.isValid)
    }
}

@Test func algorithmMenuCoversEveryNativeServerRouteType() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: root.appendingPathComponent(
        "vendor/switchyard/crates/switchyard-runner/src/algorithm.rs"), encoding: .utf8)
    let declaration = try #require(source.components(separatedBy: "pub enum AlgorithmSpec {").last)
        .components(separatedBy: "\n}\n")[0]
    let pattern = try NSRegularExpression(pattern: #"(?m)^    ([A-Z][A-Za-z]+) \{"#)
    let nativeTypes = pattern.matches(in: declaration, range: NSRange(declaration.startIndex..., in: declaration))
        .compactMap { Range($0.range(at: 1), in: declaration).map { String(declaration[$0]) } }
        .map { $0.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1_$2", options: .regularExpression).lowercased() }
    #expect(Set(nativeTypes) == Set(RoutingAlgorithm.allCases.map(\.serverType)))
}

@Test func extraSubagentTargetsAndNestedRequestOptionsSurviveMigration() throws {
    var profile = parityProfile(.stageRouter)
    profile.additionalTargets = [TaskTier(name: "Worker", summary: "", modelID: "worker-model")]
    profile.additionalTargets[0].nativeOptions = """
    [targets.worker.extra_body]
    custom_flag = true
    """
    profile.nativeRouteOptions = SwitchyardConfigWriter.defaultRouteOptions(profile: profile)
        + "\n[routes.main.subagents]\ntype = \"passthrough\"\ntarget = \"worker\"\n"
    #expect(profile.managedLiteLLMModels == ["model-0", "model-1", "worker-model"])
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("routes.toml")
    try SwitchyardConfigWriter.write(profile: profile, to: path)
    let restored = try SavedRoutingSetup.migrateGeneratedConfig(from: path)
    #expect(restored.isUsable)
    #expect(restored.profile.additionalTargets.first?.assignedModel == "worker-model")
    let document = try TOMLTable(string: SwitchyardConfigWriter.render(profile: restored.profile))
    #expect(document["targets"]?.table?["worker"]?.table?["extra_body"]?.table?["custom_flag"]?.bool == true)
    #expect(document["routes"]?.table?["main"]?.table?["subagents"]?.table?["target"]?.string == "worker")
}

@Test func aNestedSubagentJudgeRestoresItsSeparateModelAndContract() throws {
    var profile = parityProfile(.stageRouter)
    profile.judgeModelID = "separate-judge"
    profile.nativeRouteOptions = SwitchyardConfigWriter.defaultRouteOptions(profile: profile) + """

    [routes.main.subagents]
    type = "llm_classifier"
    mode = "custom"
    classify_trigger = "new_session"
    models = { judge = ["judge"], efficient = ["efficient"], capable = ["capable"], any = ["efficient", "capable"] }
    default_target = "efficient"
    prompt = "Select a target for this delegated task."
    response_schema = '{"type":"object","properties":{"target":{"type":"string","enum":["efficient","capable"]}},"required":["target"],"additionalProperties":false}'
    policy = { type = "target_selector", selector = "/target" }
    """
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("routes.toml")
    try SwitchyardConfigWriter.write(profile: profile, to: path)
    let restored = try SavedRoutingSetup.migrateGeneratedConfig(from: path)
    #expect(restored.profile.judgeModelID == "separate-judge")
    let before = try TOMLTable(string: SwitchyardConfigWriter.render(profile: profile))
    let after = try TOMLTable(string: SwitchyardConfigWriter.render(profile: restored.profile))
    #expect(before["routes"]?.table?.convert(to: .json) == after["routes"]?.table?.convert(to: .json))
}

@Test func legacyPlanExecuteMigratesToStageWithoutLosingCustomSettings() throws {
    var profile = parityProfile(.planExecute)
    profile.nativeRouteOptions = """
    type = "plan_execute"
    capable_target = "capable"
    efficient_target = "efficient"
    execution_trigger = "edit"
    planning_prompt = "Inspect first.\nKeep the user's plan."
    planner_reasoning_as_text = false
    [routes.main.tool_semantics]
    mutate = ["update_inventory"]
    """.replacingOccurrences(of: "Inspect first.\nKeep", with: "Inspect first.\\nKeep")
    let restored = try JSONDecoder().decode(RoutingProfile.self, from: JSONEncoder().encode(profile))
    #expect(restored.isValid)
    #expect(restored.algorithm == .planExecute)
    let route = try #require(TOMLTable(string: SwitchyardConfigWriter.render(profile: restored))["routes"]?.table?["main"]?.table)
    #expect(route["type"]?.string == "stage_router")
    #expect(route["picker"]?.string == "capable_first")
    #expect(route["confidence_threshold"]?.double == 0.0)
    #expect(route["capable_hold_turns"]?.int == 0)
    #expect(route["efficient_hold_turns"]?.int == -1)
    #expect(route["capable_system_prompt"]?.string == "Inspect first.\nKeep the user's plan.")
    #expect(route["planning_prompt"] == nil)
    #expect(route["execution_trigger"] == nil)
    #expect(route["tool_semantics"]?.table?["mutate"]?.array?[0]?.string == "update_inventory")
    #expect(try JSONDecoder().decode(RoutingProfile.self, from: JSONEncoder().encode(restored)) == restored)

    // Migration also covers routes.toml from an older app, not just JSON profiles.
    let directory = UserDataLocations.testSandbox.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("routes.toml")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let current = try SwitchyardConfigWriter.render(profile: parityProfile(.planExecute))
    let prefix = try #require(current.components(separatedBy: "[routes.main]").first)
    try (prefix + "[routes.main]\nid = \"switchyard-desktop\"\n" + (profile.nativeRouteOptions ?? ""))
        .write(to: path, atomically: true, encoding: .utf8)
    let migrated = try SavedRoutingSetup.migrateGeneratedConfig(from: path)
    #expect(migrated.isUsable)
    #expect(migrated.profile.nativeRouteOptions == restored.nativeRouteOptions)
}

@Test(arguments: ["execution_trigger = \"judge\"", "handoff_prompt = \"Now execute\"", "planner_reasoning_as_text = true"])
func unsupportedPlanExecuteSettingsRequireReview(_ setting: String) throws {
    var profile = parityProfile(.planExecute)
    profile.nativeRouteOptions = "type = \"plan_execute\"\ncapable_target = \"capable\"\nefficient_target = \"efficient\"\n" + setting
    let restored = try JSONDecoder().decode(RoutingProfile.self, from: JSONEncoder().encode(profile))
    #expect(!restored.isValid)
    #expect(restored.roleValidationErrors.contains { $0.contains("manual migration") })
    #expect(restored.nativeRouteOptions?.contains(setting) == true)
}

@Test func separateJudgeCanShareAnExternalModelWithoutLosingItsSettings() throws {
    var profile = parityProfile(.capability)
    profile.upstreamBaseURL = "http://127.0.0.1:4999/v1"
    profile.judgeModelID = "model-0"
    profile.judgeNativeOptions = "reasoning_effort = \"high\""
    profile.tiers[0].nativeOptions = "reasoning_effort = \"low\"\nsystem_prompt = \"Serve the user.\""
    let targets = try #require(TOMLTable(string: SwitchyardConfigWriter.render(profile: profile))["targets"]?.table)
    #expect(targets["judge"]?.table?["id"]?.string == "model-0")
    #expect(targets["judge"]?.table?["reasoning_effort"]?.string == "high")
    #expect(targets["judge"]?.table?["system_prompt"] == nil)
    #expect(targets["efficient"]?.table?["reasoning_effort"]?.string == "low")
}
