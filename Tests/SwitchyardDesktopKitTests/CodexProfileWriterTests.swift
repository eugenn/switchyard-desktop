import Foundation
import TOMLKit
import Testing
@testable import SwitchyardDesktopKit

private func sampleProfile() -> RoutingProfile {
    RoutingProfile(
        provider: .codex,
        algorithm: .stageRouter,
        tiers: [
            TaskTier(name: "Efficient", summary: "Simple.", modelID: "gpt-5.3-codex-spark"),
            TaskTier(name: "Capable", summary: "Complex.", modelID: "gpt-6-astra"),
        ]
    )
}

/// A throwaway `.codex` directory. The profile path is returned; a user
/// configuration is seeded beside it when one is asked for, so every test can
/// check that the app leaves it exactly as it found it.
private func makeCodexHome(userConfig: String? = nil) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if let userConfig {
        try userConfig.write(
            to: directory.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
    }
    return directory.appendingPathComponent("switchyard-desktop.config.toml")
}

/// Shaped like the real file the app must never touch: top-level keys, a
/// commented-out toggle, a provider table and unrelated project tables.
private let existingUserConfig = """
model = "switchyard/codex-auto"
model_provider = "switchyard_local"
model_reasoning_effort = "high"
#model = "gpt-5.6-sol"
personality = "pragmatic"

[model_providers.switchyard_local]
name = "Local Switchyard subscription router"
base_url = "http://127.0.0.1:4000/v1"
wire_api = "responses"

[projects."/Users/someone/code"]
trust_level = "trusted"
"""

// MARK: - Install

@Test func installWritesASelfContainedProfileLayer() throws {
    let profilePath = try makeCodexHome()
    defer { try? FileManager.default.removeItem(at: profilePath.deletingLastPathComponent()) }

    let profile = sampleProfile()
    try CodexProfileWriter.install(profile: profile, profilePath: profilePath)

    let table = try TOMLTable(string: String(contentsOf: profilePath, encoding: .utf8))
    #expect(table["model"]?.string == profile.routeID)
    #expect(table["model_provider"]?.string == CodexProfileWriter.providerKey)
    let provider = try #require(table["model_providers"]?.table?[CodexProfileWriter.providerKey]?.table)
    #expect(provider["base_url"]?.string == profile.proxyBaseURL)
    #expect(provider["wire_api"]?.string == "responses")
    #expect(provider["requires_openai_auth"]?.bool == true)
    #expect(
        provider["http_headers"]?.table?[CodexProfileWriter.originHeader]?.string
            == CodexProfileWriter.originValue
    )
}

@Test func installNeverTouchesTheUserConfigurationBesideIt() throws {
    let profilePath = try makeCodexHome(userConfig: existingUserConfig)
    let userConfig = profilePath.deletingLastPathComponent()
        .appendingPathComponent("config.toml")
    defer { try? FileManager.default.removeItem(at: profilePath.deletingLastPathComponent()) }

    try CodexProfileWriter.install(profile: sampleProfile(), profilePath: profilePath)

    #expect(try String(contentsOf: userConfig, encoding: .utf8) == existingUserConfig)
    // No backup of anything, either: there is nothing to put back.
    let siblings = try FileManager.default.contentsOfDirectory(
        atPath: profilePath.deletingLastPathComponent().path
    )
    #expect(Set(siblings) == ["config.toml", "switchyard-desktop.config.toml"])
}

@Test func installIsIdempotentAndReplacesAnEarlierGeneration() throws {
    let profilePath = try makeCodexHome()
    defer { try? FileManager.default.removeItem(at: profilePath.deletingLastPathComponent()) }

    var profile = sampleProfile()
    try CodexProfileWriter.install(profile: profile, profilePath: profilePath)
    let first = try String(contentsOf: profilePath, encoding: .utf8)
    try CodexProfileWriter.install(profile: profile, profilePath: profilePath)
    #expect(try String(contentsOf: profilePath, encoding: .utf8) == first)

    profile.port += 1
    try CodexProfileWriter.install(profile: profile, profilePath: profilePath)
    let rewritten = try String(contentsOf: profilePath, encoding: .utf8)
    #expect(rewritten.contains(profile.proxyBaseURL))
    #expect(!rewritten.contains(first.components(separatedBy: "\n").first(where: {
        $0.hasPrefix("base_url")
    }) ?? "base_url"))
}

@Test func installCreatesAMissingCodexDirectory() throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent(".codex", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }

    let profilePath = home.appendingPathComponent("switchyard-desktop.config.toml")
    try CodexProfileWriter.install(profile: sampleProfile(), profilePath: profilePath)

    #expect(CodexProfileWriter.isInstalled(profilePath: profilePath))
}

@Test func installRefusesAnIncompleteProfile() throws {
    let profilePath = try makeCodexHome()
    defer { try? FileManager.default.removeItem(at: profilePath.deletingLastPathComponent()) }

    var incomplete = sampleProfile()
    incomplete.tiers[0].modelID = nil

    #expect(throws: CodexProfileWriter.Failure.self) {
        try CodexProfileWriter.install(profile: incomplete, profilePath: profilePath)
    }
    #expect(!FileManager.default.fileExists(atPath: profilePath.path))
}

@Test func summaryOptOutIsStatedOnlyWhenTheRouteDropsSummaries() throws {
    var profile = sampleProfile()
    #expect(try TOMLTable(string: CodexProfileWriter.render(profile: profile))[
        "model_reasoning_summary"
    ] == nil)

    profile.advertisesReasoningSummaries = false
    #expect(try TOMLTable(string: CodexProfileWriter.render(profile: profile))[
        "model_reasoning_summary"
    ]?.string == "none")
}

// MARK: - Remove

@Test func removeDeletesTheGeneratedProfileAndReportsIt() throws {
    let profilePath = try makeCodexHome(userConfig: existingUserConfig)
    let userConfig = profilePath.deletingLastPathComponent()
        .appendingPathComponent("config.toml")
    defer { try? FileManager.default.removeItem(at: profilePath.deletingLastPathComponent()) }

    try CodexProfileWriter.install(profile: sampleProfile(), profilePath: profilePath)
    #expect(try CodexProfileWriter.remove(profilePath: profilePath))

    #expect(!FileManager.default.fileExists(atPath: profilePath.path))
    #expect(try String(contentsOf: userConfig, encoding: .utf8) == existingUserConfig)
}

@Test func removeIsANoOpWhenNoProfileWasWritten() throws {
    let profilePath = try makeCodexHome()
    defer { try? FileManager.default.removeItem(at: profilePath.deletingLastPathComponent()) }

    #expect(try CodexProfileWriter.remove(profilePath: profilePath) == false)
}

@Test func removeLeavesAFileThisAppDidNotGenerate() throws {
    let profilePath = try makeCodexHome()
    defer { try? FileManager.default.removeItem(at: profilePath.deletingLastPathComponent()) }
    let foreign = "model = \"gpt-6-astra\"\nmodel_provider = \"someone_else\"\n"
    try foreign.write(to: profilePath, atomically: true, encoding: .utf8)

    #expect(throws: CodexProfileWriter.Failure.self) {
        try CodexProfileWriter.remove(profilePath: profilePath)
    }
    #expect(try String(contentsOf: profilePath, encoding: .utf8) == foreign)
}

@Test func removeDeletesTheStateCodexWroteIntoTheProfileFile() throws {
    let profilePath = try makeCodexHome()
    defer { try? FileManager.default.removeItem(at: profilePath.deletingLastPathComponent()) }
    let codexResidue = "[tui.model_availability_nux]\n\"gpt-5.5\" = 4\n"
    try codexResidue.write(to: profilePath, atomically: true, encoding: .utf8)

    #expect(try CodexProfileWriter.remove(profilePath: profilePath))
    #expect(!FileManager.default.fileExists(atPath: profilePath.path))
}

@Test func removeLeavesATuiOnlyLookingFileThatAlsoCarriesSettings() throws {
    let profilePath = try makeCodexHome()
    defer { try? FileManager.default.removeItem(at: profilePath.deletingLastPathComponent()) }
    let mixed = "model = \"gpt-6-astra\"\n\n[tui.model_availability_nux]\n\"gpt-5.5\" = 4\n"
    try mixed.write(to: profilePath, atomically: true, encoding: .utf8)

    #expect(throws: CodexProfileWriter.Failure.self) {
        try CodexProfileWriter.remove(profilePath: profilePath)
    }
    #expect(try String(contentsOf: profilePath, encoding: .utf8) == mixed)
}

// MARK: - Reading

@Test func readingReportsWhatTheProfileCurrentlySelects() throws {
    let profilePath = try makeCodexHome()
    defer { try? FileManager.default.removeItem(at: profilePath.deletingLastPathComponent()) }

    #expect(CodexProfileWriter.readSelection(profilePath: profilePath) == nil)
    #expect(!CodexProfileWriter.isInstalled(profilePath: profilePath))

    let profile = sampleProfile()
    try CodexProfileWriter.install(profile: profile, profilePath: profilePath)
    let selection = try #require(CodexProfileWriter.readSelection(profilePath: profilePath))
    #expect(selection.model == profile.routeID)
    #expect(selection.selectsManagedProvider)
    #expect(CodexProfileWriter.isInstalled(profilePath: profilePath))
}

@Test func anUnparsableProfileReadsAsNoSelection() throws {
    let profilePath = try makeCodexHome()
    defer { try? FileManager.default.removeItem(at: profilePath.deletingLastPathComponent()) }
    try "model = \"unterminated".write(to: profilePath, atomically: true, encoding: .utf8)

    #expect(CodexProfileWriter.readSelection(profilePath: profilePath) == nil)
    #expect(!CodexProfileWriter.isInstalled(profilePath: profilePath))
}

// MARK: - Locations

@Test func codexLocationsNameBothFilesInTheSameHome() {
    let home = URL(fileURLWithPath: "/tmp/example-user", isDirectory: true)
    #expect(
        CodexLocations.configURL(codexHome: nil, userHome: home).path
            == "/tmp/example-user/.codex/config.toml"
    )
    #expect(
        CodexLocations.profileURL(codexHome: nil, userHome: home).path
            == "/tmp/example-user/.codex/switchyard-desktop.config.toml"
    )
    #expect(
        CodexLocations.profileURL(codexHome: "/tmp/custom-codex", userHome: home).path
            == "/tmp/custom-codex/switchyard-desktop.config.toml"
    )
}

@Test func theLaunchCommandNamesTheGeneratedProfile() {
    #expect(CodexLocations.launchCommand == "codex --profile \(CodexLocations.profileName)")
    #expect(
        CodexProfileWriter.defaultProfileURL.lastPathComponent
            == "\(CodexLocations.profileName).config.toml"
    )
}

// MARK: - Manual Desktop snippet

@Test func manualSnippetMatchesTheProfileSelectionExactly() throws {
    let profile = sampleProfile()
    let profilePath = try makeCodexHome()
    defer { try? FileManager.default.removeItem(at: profilePath.deletingLastPathComponent()) }
    try CodexProfileWriter.install(profile: profile, profilePath: profilePath)
    let generated = try TOMLTable(string: String(contentsOf: profilePath, encoding: .utf8))

    let snippet = try TOMLTable(string: CodexProfileWriter.manualConfigSnippet(profile: profile))

    // Same selection and provider table as the generated layer — only the
    // surrounding comments differ, since this text is meant for a different
    // file with a different meaning (the user's own default, not a --profile
    // layer).
    #expect(snippet["model"]?.string == generated["model"]?.string)
    #expect(snippet["model_provider"]?.string == generated["model_provider"]?.string)
    #expect(
        snippet["model_providers"]?.table?[CodexProfileWriter.providerKey]?.table
            == generated["model_providers"]?.table?[CodexProfileWriter.providerKey]?.table
    )
}

@Test func manualSnippetNeverMentionsTheProfileFlag() {
    // This text is pasted into config.toml directly, so it must not imply the
    // reader still needs `--profile switchyard-desktop` to get it.
    let snippet = CodexProfileWriter.manualConfigSnippet(profile: sampleProfile())
    #expect(!snippet.contains("--profile"))
}

@Test func manualSnippetIsNeverWrittenByInstall() throws {
    let profilePath = try makeCodexHome()
    defer { try? FileManager.default.removeItem(at: profilePath.deletingLastPathComponent()) }
    try CodexProfileWriter.install(profile: sampleProfile(), profilePath: profilePath)
    let generated = try String(contentsOf: profilePath, encoding: .utf8)
    #expect(!generated.contains("Paste into"))
}
