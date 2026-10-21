import Foundation
import Testing
import TOMLKit
@testable import SwitchyardDesktopKit

/// Two tiers — the `stage_router` shape.
private let profile = RoutingProfile(
    provider: .codex,
    algorithm: .stageRouter,
    tiers: [
        TaskTier(name: "Efficient", summary: "Small, local edits.", modelID: "gpt-5.3-codex-spark"),
        TaskTier(name: "Capable", summary: "Hard, ambiguous work.", modelID: "gpt-6-astra"),
    ]
)

/// Three targets — the `llm_classifier` shape.
private let classifierTargets = [
    TaskTier(name: "Efficient", summary: "Small, local edits.", modelID: "gpt-5.3-codex-spark"),
    TaskTier(name: "Balanced", summary: "Everyday feature work.", modelID: "gpt-5.6-terra"),
    TaskTier(name: "Capable", summary: "Hard, ambiguous work.", modelID: "gpt-6-astra"),
]

private let threeTierProfile = RoutingProfile(
    provider: .codex,
    algorithm: .llmClassifier,
    tiers: classifierTargets,
    classifierTargetID: classifierTargets[1].id,
    defaultTargetID: classifierTargets[2].id
)

/// The real binary, if this machine has one. Dry-run tests skip themselves without it.
private var switchyardBinary: URL? {
    SwitchyardBinaryLocator.locate()
}

@Test func renderProducesTheExpectedStageRouterConfig() throws {
    let document = try TOMLTable(string: SwitchyardConfigWriter.render(profile: profile))
    let route = try #require(document["routes"]?.table?["main"]?.table)
    #expect(route["type"]?.string == "stage_router")
    #expect(route["capable_target"]?.string == "capable")
    #expect(route["efficient_target"]?.string == "efficient")
    #expect(route["picker"]?.string == "efficient_first")
    #expect(route["confidence_threshold"]?.double == 0.5)
    #expect(route["recent_turn_window"]?.int == 3)
    #expect(route["classifier"] == nil)

}

@Test func renderReflectsACustomUpstreamAndRouteID() throws {
    var custom = profile
    custom.upstreamBaseURL = "http://127.0.0.1:4001/v1"
    custom.routeID = "my-route"
    let toml = try SwitchyardConfigWriter.render(profile: custom)
    #expect(toml.contains(#"base_url = "http://127.0.0.1:4001/v1""#))
    #expect(toml.contains("forward_auth = false"))
    #expect(toml.contains(#"id = "my-route""#))
}

@Test func quotedRouteSettingsCannotInjectTOML() throws {
    var custom = profile
    custom.routeID = "route\"\n[targets.injected]"
    custom.upstreamBaseURL = "https://api.example.com/v1?bad"
    // The invalid URL itself is rejected, so retain a valid URL to inspect
    // basic-string escaping for the editable route identifier.
    custom.upstreamBaseURL = "https://api.example.com/v1"
    let toml = try SwitchyardConfigWriter.render(profile: custom)

    #expect(toml.contains(#"id = "route\"\n[targets.injected]""#))
    #expect(!toml.contains("\n[targets.injected]\n"))
}

@Test func renderRefusesAnIncompleteProfile() {
    var incomplete = profile
    incomplete.tiers[1].modelID = nil
    #expect(throws: SwitchyardConfigWriter.Failure.self) {
        try SwitchyardConfigWriter.render(profile: incomplete)
    }
}

@Test func threeTiersRenderAsACustomClassifier() throws {
    let toml = try SwitchyardConfigWriter.render(profile: threeTierProfile)

    #expect(toml.contains(#"type = "llm_classifier""#))
    #expect(toml.contains(#"mode = "custom""#))
    #expect(!toml.contains("stage_router"))

    // Every tier is a target, and a selectable one.
    for name in ["efficient", "balanced", "capable"] {
        #expect(toml.contains("[targets.\(name)]"))
    }
    // Each tier is its own model group, and `any` is the route's fallback order.
    #expect(toml.contains("""
        [routes.main.models]
        # Every selectable target, in last-resort fallback order.
        any = ["efficient", "balanced", "capable"]
        # The judge's own candidates. Never a routing destination.
        judge = ["balanced"]
        efficient = ["efficient"]
        balanced = ["balanced"]
        capable = ["capable"]
        """))

    // The judge runs on the middle tier; failures fall back to the most capable
    // group. Both are group names now, not target names.
    #expect(toml.contains(#"default_target = "capable""#))
    #expect(!toml.contains("classifier_target"))

    // Each tier is described to the judge in its own words.
    #expect(toml.contains("- balanced: Everyday feature work."))
    #expect(!toml.contains("Prefer the least powerful"))

    #expect(toml.contains(#"[routes.main.policy]"#))
    #expect(toml.contains(#"selector = "/decision/target""#))
    #expect(toml.contains(#""enum": ["efficient", "balanced", "capable"]"#))
}

@Test func twoTargetClassifierDoesNotFallBackToStageRouting() throws {
    var twoTargetClassifier = RoutingProfile(
        provider: .codex,
        algorithm: .llmClassifier,
        tiers: [
            TaskTier(name: "Fast", summary: "Small work.", modelID: "m1"),
            TaskTier(name: "Strong", summary: "Hard work.", modelID: "m2"),
        ]
    )
    twoTargetClassifier.classifierTargetID = twoTargetClassifier.tiers[0].id
    twoTargetClassifier.defaultTargetID = twoTargetClassifier.tiers[1].id

    let toml = try SwitchyardConfigWriter.render(profile: twoTargetClassifier)
    #expect(toml.contains(#"type = "llm_classifier""#))
    #expect(!toml.contains(#"type = "stage_router""#))
    #expect(toml.contains(#"any = ["fast", "strong"]"#))
}

@Test func tierTargetNamesAreUniqueAndTOMLSafe() throws {
    var awkward = RoutingProfile(
        provider: .codex,
        algorithm: .llmClassifier,
        tiers: [
            TaskTier(name: "Fast & cheap!", summary: "a", modelID: "m1"),
            TaskTier(name: "Fast & cheap!", summary: "b", modelID: "m2"),
            TaskTier(name: "3rd", summary: "c", modelID: "m3"),
        ]
    )
    awkward.classifierTargetID = awkward.tiers[0].id
    awkward.defaultTargetID = awkward.tiers[2].id
    #expect(awkward.targetNames == ["fast_cheap", "fast_cheap2", "t3rd"])

    let toml = try SwitchyardConfigWriter.render(profile: awkward)
    #expect(toml.contains("[targets.fast_cheap]"))
    #expect(toml.contains("[targets.fast_cheap2]"))
}

/// A slug can only carry ASCII, so a tier named in another script would otherwise
/// reach the judge as a meaningless "tier2".
@Test func aTierNameTheSlugCannotCarryStillReachesTheJudge() throws {
    var profile = RoutingProfile(
        provider: .codex,
        algorithm: .llmClassifier,
        tiers: [
            TaskTier(name: "Быстрый", summary: "Мелкие правки.", modelID: "m1"),
            TaskTier(name: "Средний", summary: "Обычная работа.", modelID: "m2"),
            TaskTier(name: "Сложный", summary: "Трудные задачи.", modelID: "m3"),
        ]
    )
    profile.classifierTargetID = profile.tiers[1].id
    profile.defaultTargetID = profile.tiers[2].id
    #expect(profile.targetNames == ["tier1", "tier2", "tier3"])

    let toml = try SwitchyardConfigWriter.render(profile: profile)
    #expect(toml.contains("- tier2: Средний — Обычная работа."))
    // English defaults keep the shorter form, with no name repeated before the dash.
    #expect(try SwitchyardConfigWriter.render(profile: threeTierProfile)
        .contains("- balanced: Everyday feature work."))
}

@Test func aTierDescriptionCannotBreakOutOfTheTOMLString() throws {
    var sneaky = threeTierProfile
    sneaky.tiers[1].summary = "ends the string ''' and adds\nkeys"
    let toml = try SwitchyardConfigWriter.render(profile: sneaky)
    // Exactly two literal-string delimiters: the prompt's and the schema's.
    #expect(toml.components(separatedBy: "'''").count - 1 == 4)
}

@Test func writeCreatesTheFileAndReadsBackIdentically() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("routes.toml")

    try SwitchyardConfigWriter.write(profile: profile, to: target)

    let written = try String(contentsOf: target, encoding: .utf8)
    #expect(written == (try SwitchyardConfigWriter.render(profile: profile)))
}

@Test func defaultConfigPathLivesInThisAppsSupportDirectory() {
    let path = SwitchyardConfigWriter.defaultConfigURL.path
    // Under a test run the same directory is the per-process sandbox, so the
    // shape is asserted rather than the user's own location.
    #expect(path.hasSuffix("switchyard-desktop/routes.toml"))
    #expect(path.hasPrefix(UserDataLocations.supportDirectory.path))
    #expect(!path.contains("NVIDIA"))
}

@Test func generatedConfigPassesTheRealDryRun() throws {
    guard let binary = switchyardBinary else { return }
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("routes.toml")

    try SwitchyardConfigWriter.write(profile: profile, to: target)
    try SwitchyardConfigWriter.validate(configPath: target, binaryPath: binary)
}

/// The compatibility guard for the classifier route shape: only the real binary
/// can say whether this app's generated `llm_classifier` is still valid.
@Test func generatedThreeTierConfigPassesTheRealDryRun() throws {
    guard let binary = switchyardBinary else { return }
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("routes.toml")

    try SwitchyardConfigWriter.write(profile: threeTierProfile, to: target)
    try SwitchyardConfigWriter.validate(configPath: target, binaryPath: binary)
}

/// A judge on its own client is the one place this app writes two
/// `[llm_clients]` entries, and Switchyard refuses a model id reached through
/// both — only the real binary can confirm the judge's name keeps them apart.
@Test func generatedDirectClassifierConfigPassesTheRealDryRun() throws {
    guard let binary = switchyardBinary else { return }
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("routes.toml")

    try SwitchyardConfigWriter.write(profile: directClassifierProfile, to: target)
    try SwitchyardConfigWriter.validate(configPath: target, binaryPath: binary)
}

/// Six tiers is the supported maximum — check the biggest shape the app can emit.
@Test func generatedSixTierConfigPassesTheRealDryRun() throws {
    guard let binary = switchyardBinary else { return }
    var six = threeTierProfile
    while six.canAddTier { six.addTier() }
    for index in six.tiers.indices where six.tiers[index].assignedModel == nil {
        six.tiers[index].modelID = "gpt-5.\(index)"
        six.tiers[index].summary = "Work for target \(index + 1)."
    }
    #expect(six.tiers.count == TaskTier.maximumCount)

    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("routes.toml")

    try SwitchyardConfigWriter.write(profile: six, to: target)
    try SwitchyardConfigWriter.validate(configPath: target, binaryPath: binary)
}

@Test func malformedConfigFailsTheRealDryRun() throws {
    guard let binary = switchyardBinary else { return }
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("routes.toml")

    // A route pointing at a target that does not exist.
    try """
    schema_version = 1

    [llm_clients.openai]
    format = "openai_responses"
    base_url = "http://127.0.0.1:4101/v1"
    forward_auth = false

    [routes.main]
    id = "broken"
    type = "passthrough"
    target = "missing"
    """.write(to: target, atomically: true, encoding: .utf8)

    #expect(throws: SwitchyardConfigWriter.Failure.self) {
        try SwitchyardConfigWriter.validate(configPath: target, binaryPath: binary)
    }
}

@Test func validateRejectsANonExecutableBinaryPath() {
    let missing = URL(fileURLWithPath: "/nonexistent/switchyard-server")
    #expect(throws: SwitchyardConfigWriter.Failure.binaryNotExecutable(missing.path)) {
        try SwitchyardConfigWriter.validate(
            configPath: URL(fileURLWithPath: "/tmp/whatever.toml"),
            binaryPath: missing
        )
    }
}


// MARK: - Image input

@MainActor
private func imageCapableProfile(
    algorithm: RoutingAlgorithm,
    imageCapable: Set<String>
) -> RoutingProfile {
    var profile = RoutingProfile(algorithm: algorithm)
    profile.imageCapableModelIDs = imageCapable
    profile.tiers[0].modelID = "sees-a"
    profile.tiers[1].modelID = "sees-b"
    profile.tiers[0].summary = "Simple work."
    profile.tiers[1].summary = "Complex work."
    if algorithm == .llmClassifier {
        profile.classifierTargetID = profile.tiers[0].id
        profile.defaultTargetID = profile.tiers[1].id
    }
    return profile
}

@MainActor
@Test func aRouteDeclaresImageInputOnlyWhenEveryTargetAcceptsIt() throws {
    let profile = imageCapableProfile(algorithm: .stageRouter, imageCapable: ["sees-a", "sees-b"])

    let toml = try SwitchyardConfigWriter.render(profile: profile, serverSupportsVision: true)

    #expect(toml.contains("vision = true"))
    #expect(profile.advertisesImageInput)
}

@MainActor
@Test func oneTextOnlyTargetKeepsTheWholeRouteTextOnly() throws {
    // Codex drops an attached image before sending when the route reads
    // text-only, so a mixed route must not claim image support.
    let profile = imageCapableProfile(algorithm: .stageRouter, imageCapable: ["sees-a"])

    let toml = try SwitchyardConfigWriter.render(profile: profile, serverSupportsVision: true)

    #expect(!toml.contains("vision = true"))
    #expect(toml.contains("sees-b"))
    #expect(!profile.advertisesImageInput)
    #expect(profile.textOnlyAssignedModels == ["sees-b"])
}

@MainActor
@Test func aServerWithoutTheVisionKeyNeverReceivesIt() throws {
    // Older switchyard-server builds reject the whole file on an unknown key.
    let profile = imageCapableProfile(algorithm: .stageRouter, imageCapable: ["sees-a", "sees-b"])

    let toml = try SwitchyardConfigWriter.render(profile: profile, serverSupportsVision: false)

    #expect(!toml.contains("vision = true"))
    // …and the generated file says why, rather than silently dropping it.
    #expect(toml.contains("this switchyard-server build does not"))
}

/// An upstream may serve the judge without enforcing the route's response
/// schema — Codex's own backend does — and a model that never sees the schema
/// answers the request instead of routing it. The prompt has to carry both the
/// instruction and the exact reply shape.
@Test func theJudgePromptStatesTheReplyShapeItself() throws {
    let toml = try SwitchyardConfigWriter.render(profile: threeTierProfile)

    #expect(toml.contains("Do not answer or perform the request. Classify it."))
    #expect(toml.contains("Reply with this JSON object and nothing else:"))
    #expect(toml.contains(
        #"{"decision": {"target": "<one of: efficient, balanced, capable>"}}"#
    ))
}

@MainActor
@Test func aClassifierRouteAlsoDeclaresImageInput() throws {
    let profile = imageCapableProfile(algorithm: .llmClassifier, imageCapable: ["sees-a", "sees-b"])

    let toml = try SwitchyardConfigWriter.render(profile: profile, serverSupportsVision: true)

    #expect(toml.contains("vision = true"))
    // The key belongs to the route table, before its prompt block. Matched at
    // the start of a line: a target's own system_prompt ends in the same
    // characters and is written earlier in the file.
    let visionIndex = try #require(toml.range(of: "vision = true")).lowerBound
    let promptIndex = try #require(toml.range(of: "\nprompt = ")).lowerBound
    #expect(visionIndex < promptIndex)
}

// MARK: - Judge client

/// The same three-tier classifier, but talking straight to ChatGPT.
private var directClassifierProfile: RoutingProfile {
    var profile = threeTierProfile
    profile.upstreamBaseURL = "https://chatgpt.com/backend-api/codex"
    return profile
}

@Test func aDirectClassifierGivesTheJudgeItsOwnLiteLLMClient() throws {
    let toml = try SwitchyardConfigWriter.render(profile: directClassifierProfile)

    // Served turns keep the direct, credential-forwarding client.
    #expect(toml.contains(#"base_url = "https://chatgpt.com/backend-api/codex""#))
    #expect(toml.contains("forward_auth = true"))

    // The judge gets a loopback client of its own, and no caller credential.
    #expect(toml.contains("[llm_clients.judge_litellm]"))
    #expect(toml.contains(#"base_url = "\#(LiteLLMProcessManager.upstream)""#))
    // The judge asks for the same model under a name of its own: Switchyard
    // keys execution by model id and rejects one id on two clients.
    #expect(toml.contains("""
        [targets.judge]
        id = "judge-gpt-5.6-terra"
        llm_client = "judge_litellm"
        """))
    #expect(toml.contains(#"judge = ["judge"]"#))

    // A judge-only target is never a routing destination: it stays out of `any`
    // and out of the tier groups.
    #expect(toml.contains(#"any = ["efficient", "balanced", "capable"]"#))
    #expect(!toml.contains(#""enum": ["efficient", "balanced", "capable", "judge"]"#))
}

@Test func aLiteLLMClassifierJudgesOnItsOwnClient() throws {
    let toml = try SwitchyardConfigWriter.render(profile: threeTierProfile)

    #expect(!toml.contains("judge_litellm"))
    #expect(!toml.contains("[targets.judge]"))
    #expect(toml.contains(#"judge = ["balanced"]"#))
}

@Test func aDirectStageRouterNeedsNoJudgeClient() throws {
    var direct = profile
    direct.upstreamBaseURL = "https://chatgpt.com/backend-api/codex"

    let toml = try SwitchyardConfigWriter.render(profile: direct)
    #expect(!toml.contains("judge_litellm"))
}

/// `judge` and `any` name model groups Switchyard reserves, so a tier called
/// "Judge" takes the next free name and the judge-only target keeps `judge`.
@Test func aTierNeverClaimsAReservedGroupName() throws {
    var collides = directClassifierProfile
    collides.tiers[1].name = "Judge"

    #expect(collides.targetNames == ["efficient", "judge2", "capable"])

    let toml = try SwitchyardConfigWriter.render(profile: collides)
    #expect(toml.contains("""
        [targets.judge2]
        id = "gpt-5.6-terra"
        llm_client = "openai"
        """))
    #expect(toml.contains("""
        [targets.judge]
        id = "judge-gpt-5.6-terra"
        llm_client = "judge_litellm"
        """))
    #expect(toml.contains(#"judge = ["judge"]"#))
    #expect(toml.contains(#"judge2 = ["judge2"]"#))
}

/// The same reservation for `any`, whose group is the whole fallback pool.
@Test func aTierNamedAnyDoesNotClaimTheFallbackPool() throws {
    var collides = threeTierProfile
    collides.tiers[0].name = "Any"

    #expect(collides.targetNames == ["any2", "balanced", "capable"])

    let toml = try SwitchyardConfigWriter.render(profile: collides)
    #expect(toml.contains(#"any = ["any2", "balanced", "capable"]"#))
    #expect(toml.contains(#"any2 = ["any2"]"#))
}

// MARK: - Reasoning summaries

/// Summary preferences belong to Codex, not the server route.
@Test func advertisedReasoningSummariesStayOutOfTheGeneratedFile() throws {
    #expect(profile.advertisesReasoningSummaries)
    #expect(try !SwitchyardConfigWriter.render(profile: profile).contains("reasoning_summaries"))
    #expect(
        try !SwitchyardConfigWriter.render(profile: threeTierProfile).contains("reasoning_summaries")
    )
}

@Test func optingOutKeepsReasoningSummariesOutOfBothServerAlgorithms() throws {
    var stage = profile
    stage.advertisesReasoningSummaries = false
    let stageTOML = try SwitchyardConfigWriter.render(profile: stage)
    #expect(!stageTOML.contains("reasoning_summaries"))

    var classifier = threeTierProfile
    classifier.advertisesReasoningSummaries = false
    let classifierTOML = try SwitchyardConfigWriter.render(profile: classifier)
    #expect(!classifierTOML.contains("reasoning_summaries"))
}

@Test func anOptedOutRouteStillPassesTheRealDryRun() throws {
    guard let binary = switchyardBinary else { return }
    var opted = threeTierProfile
    opted.advertisesReasoningSummaries = false
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("routes.toml")

    try SwitchyardConfigWriter.write(profile: opted, to: target)
    try SwitchyardConfigWriter.validate(configPath: target, binaryPath: binary)
}

// MARK: - Context window

private func windowedProfile(_ windows: [String: Int]) -> RoutingProfile {
    var custom = threeTierProfile
    custom.modelContextWindows = windows
    return custom
}

/// Without this key Codex falls back to its own 272k default, well under what
/// the routed models take.
@Test func renderAdvertisesTheSmallestWindowEveryTargetAccepts() throws {
    let custom = windowedProfile([
        "gpt-5.3-codex-spark": 272_000,
        "gpt-5.6-terra": 872_000,
        "gpt-6-astra": 872_000,
    ])
    let document = try TOMLTable(string: SwitchyardConfigWriter.render(profile: custom))
    let route = try #require(document["routes"]?.table?["main"]?.table)

    #expect(route["context_window"]?.int == 272_000)
}

@Test func renderAdvertisesTheFullWindowWhenEveryTargetAgrees() throws {
    let custom = windowedProfile([
        "gpt-5.3-codex-spark": 872_000,
        "gpt-5.6-terra": 872_000,
        "gpt-6-astra": 872_000,
    ])
    let toml = try SwitchyardConfigWriter.render(profile: custom)
    let route = try #require(try TOMLTable(string: toml)["routes"]?.table?["main"]?.table)

    #expect(route["context_window"]?.int == 872_000)
    // Nothing is holding the route down, so there is nothing to explain.
    #expect(!toml.contains("The largest window every selectable target accepts"))
}

@Test func renderNamesTheTargetHoldingTheWindowDown() throws {
    let toml = try SwitchyardConfigWriter.render(profile: windowedProfile([
        "gpt-5.3-codex-spark": 272_000,
        "gpt-5.6-terra": 872_000,
        "gpt-6-astra": 872_000,
    ]))

    #expect(toml.contains("gpt-5.3-codex-spark"))
    #expect(toml.contains("takes"))
}

@Test func renderHoldsTheWindowAtTheStandardSizeWhenLongContextIsOff() throws {
    var custom = windowedProfile([
        "gpt-5.3-codex-spark": 872_000,
        "gpt-5.6-terra": 872_000,
        "gpt-6-astra": 872_000,
    ])
    custom.allowsLongContext = false
    let toml = try SwitchyardConfigWriter.render(profile: custom)
    let route = try #require(try TOMLTable(string: toml)["routes"]?.table?["main"]?.table)

    #expect(route["context_window"]?.int == 272_000)
    #expect(toml.contains("Long context is off"))
}

/// An undiscovered window means the smallest is unknown; Codex keeps its own
/// default rather than being promised more than a target can serve.
@Test func renderOmitsTheWindowWhenATargetIsUndiscovered() throws {
    let toml = try SwitchyardConfigWriter.render(profile: windowedProfile([
        "gpt-5.3-codex-spark": 272_000,
        "gpt-5.6-terra": 872_000,
    ]))
    let route = try #require(try TOMLTable(string: toml)["routes"]?.table?["main"]?.table)

    #expect(route["context_window"] == nil)
}

/// Native options own the whole route body. A window written there must not
/// collide with a second one — TOML rejects the duplicate key outright.
@Test func renderLeavesANativeWindowAlone() throws {
    let target = TaskTier(name: "Target", summary: "Everything.", modelID: "gpt-6-astra")
    var custom = RoutingProfile(provider: .codex, algorithm: .passthrough, tiers: [target])
    custom.modelContextWindows = ["gpt-6-astra": 872_000]
    custom.nativeRouteOptions = """
        type = "passthrough"
        target = "target"
        context_window = 400000
        """
    let route = try #require(
        try TOMLTable(string: SwitchyardConfigWriter.render(profile: custom))["routes"]?
            .table?["main"]?.table
    )

    #expect(route["context_window"]?.int == 400_000)
}

/// Only the real binary can say whether it still takes the route window key.
@Test func advertisedWindowPassesTheRealDryRun() throws {
    guard let binary = switchyardBinary else { return }
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("routes.toml")

    try SwitchyardConfigWriter.write(
        profile: windowedProfile([
            "gpt-5.3-codex-spark": 872_000,
            "gpt-5.6-terra": 872_000,
            "gpt-6-astra": 872_000,
        ]),
        to: target
    )
    try SwitchyardConfigWriter.validate(configPath: target, binaryPath: binary)
}

// MARK: - Roles

private func roleRenderProfile() -> RoutingProfile {
    var profile = RoutingProfile(provider: .codex, algorithm: .llmClassifier)
    profile.tiers[0].modelID = "gpt-5.6-luna"
    profile.tiers[1].modelID = "gpt-6-astra"
    profile.classifierTargetID = profile.tiers[0].id
    profile.defaultTargetID = profile.tiers[1].id
    return profile
}

@Test func renderGivesEachTargetItsRolesReasoningEffort() throws {
    let profile = roleRenderProfile()
    let efforts = profile.tiers.map { profile.effort(of: $0)?.rawValue }
    let document = try TOMLTable(string: SwitchyardConfigWriter.render(profile: profile))
    let targets = try #require(document["targets"]?.table)

    #expect(targets.keys.sorted().count == profile.tiers.count)
    for (name, effort) in zip(profile.allTargetNames, efforts) {
        #expect(targets[name]?.table?["reasoning_effort"]?.string == effort)
    }
}

/// Native target settings are the user's own words and are not overruled.
@Test func aTargetsOwnEffortWinsOverItsRoles() throws {
    var profile = roleRenderProfile()
    profile.tiers[0].nativeOptions = "reasoning_effort = \"ultra\""
    let document = try TOMLTable(string: SwitchyardConfigWriter.render(profile: profile))
    let name = try #require(profile.allTargetNames.first)

    #expect(document["targets"]?.table?[name]?.table?["reasoning_effort"]?.string == "ultra")
}

@Test func theJudgePromptComesFromTheClassifierRole() throws {
    var profile = roleRenderProfile()
    var classifier = try #require(profile.classifierRole)
    classifier.text = """
        Sort this request.

        \(RoutingRole.targetsPlaceholder)

        Answer with one of: \(RoutingRole.targetNamesPlaceholder)
        """
    profile.updateRole(classifier)

    let prompt = try #require(
        try TOMLTable(string: SwitchyardConfigWriter.render(profile: profile))["routes"]?
            .table?["main"]?.table?["prompt"]?.string
    )

    // A TOML multi-line literal keeps the newline before its closing delimiter.
    let body = prompt.trimmingCharacters(in: .newlines)
    #expect(body.hasPrefix("Sort this request."))
    #expect(body.contains("- \(profile.allTargetNames[0]): "))
    #expect(body.hasSuffix("Answer with one of: \(profile.allTargetNames.joined(separator: ", "))"))
}

/// The group list is generated, so it cannot drift from the targets however the
/// template around it is rewritten.
@Test func theGroupListFollowsTheTargetsWhateverTheTemplateSays() throws {
    var profile = roleRenderProfile()
    var classifier = try #require(profile.classifierRole)
    classifier.text = RoutingRole.targetsPlaceholder
    profile.updateRole(classifier)
    profile.removeTier(id: profile.tiers[0].id)
    profile.classifierTargetID = profile.tiers[0].id
    profile.defaultTargetID = profile.tiers[0].id
    profile.tiers.append(TaskTier(name: "Extra", summary: "Anything else.", modelID: "gpt-5.5"))

    let prompt = try #require(
        try TOMLTable(string: SwitchyardConfigWriter.render(profile: profile))["routes"]?
            .table?["main"]?.table?["prompt"]?.string
    )

    #expect(prompt.trimmingCharacters(in: .newlines).split(separator: "\n").count == profile.tiers.count)
    for name in profile.allTargetNames { #expect(prompt.contains("- \(name)")) }
}

@Test func roleDrivenConfigPassesTheRealDryRun() throws {
    guard let binary = switchyardBinary else { return }
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("routes.toml")

    try SwitchyardConfigWriter.write(profile: roleRenderProfile(), to: target)
    try SwitchyardConfigWriter.validate(configPath: target, binaryPath: binary)
}

/// The judge weighs one short classification per turn, so its effort is set
/// apart from the models that serve the work.
@Test func theJudgeTakesItsReasoningEffortFromTheClassifierRole() throws {
    var profile = roleRenderProfile()
    profile.judgeModelID = "gpt-5.6-luna"
    profile.updateRole(try #require(profile.classifierRole).with(effort: .low))
    let judge = try #require(profile.judgeTargetName)

    let document = try TOMLTable(string: SwitchyardConfigWriter.render(profile: profile))

    #expect(document["targets"]?.table?[judge]?.table?["reasoning_effort"]?.string == "low")
}

/// A judge weighs one short classification per turn and runs on every request,
/// so it starts low rather than on whatever the model defaults to.
@Test func theBuiltInClassifierJudgesAtLowEffort() throws {
    let profile = roleRenderProfile()
    let judge = try #require(RoutingProfile(
        provider: .codex, algorithm: .llmClassifier
    ).classifierRole)

    #expect(judge.effort == .low)
    #expect(profile.classifierRole?.effort == .low)
}

/// Put back on the model's default, the judge block says nothing at all.
@Test func aClassifierRoleOnTheModelDefaultLeavesTheJudgeAlone() throws {
    var profile = roleRenderProfile()
    profile.judgeModelID = "gpt-5.6-luna"
    profile.updateRole(try #require(profile.classifierRole).with(effort: nil))
    let judge = try #require(profile.judgeTargetName)

    let document = try TOMLTable(string: SwitchyardConfigWriter.render(profile: profile))

    #expect(document["targets"]?.table?[judge]?.table?["reasoning_effort"] == nil)
}

@Test func judgeTargetOptionsWinOverTheClassifierRole() throws {
    var profile = roleRenderProfile()
    profile.judgeModelID = "gpt-5.6-luna"
    profile.judgeNativeOptions = "reasoning_effort = \"high\""
    profile.updateRole(try #require(profile.classifierRole).with(effort: .low))
    let judge = try #require(profile.judgeTargetName)

    let document = try TOMLTable(string: SwitchyardConfigWriter.render(profile: profile))

    #expect(document["targets"]?.table?[judge]?.table?["reasoning_effort"]?.string == "high")
}

@Test func aJudgeWithItsOwnEffortPassesTheRealDryRun() throws {
    guard let binary = switchyardBinary else { return }
    var profile = roleRenderProfile()
    profile.judgeModelID = "gpt-5.6-luna"
    profile.updateRole(try #require(profile.classifierRole).with(effort: .low))
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("routes.toml")

    try SwitchyardConfigWriter.write(profile: profile, to: target)
    try SwitchyardConfigWriter.validate(configPath: target, binaryPath: binary)
}
