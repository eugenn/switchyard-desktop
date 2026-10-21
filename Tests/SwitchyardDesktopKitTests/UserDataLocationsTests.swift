import Foundation
import Testing
@testable import SwitchyardDesktopKit

/// The suite builds default-constructed objects, and those objects act on
/// files: they restore a Codex configuration, delete a backup, clear the
/// active-route record, overwrite the saved setup. Every default location must
/// therefore resolve inside this process's sandbox, or a test run silently
/// edits the machine it runs on.
///
/// Regression: a run of this suite once restored the live `~/.codex/config.toml`
/// from its backup, deleted that backup and the session record, and replaced
/// `saved-routing-setup.json` with a two-target fixture — because a test built
/// a `WizardModel` without injecting its stores.

/// Where the real files live, spelled out independently of the code under test
/// so a mistake in `UserDataLocations` cannot make these assertions vacuous.
private var realSupportDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/switchyard-desktop", isDirectory: true)
        .standardizedFileURL
}

private var realCodexDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
        .standardizedFileURL
}

@Test func theSuiteKnowsItIsUnderTest() {
    // Everything below depends on this one signal, so its failure has to read
    // as its own result rather than as five unrelated ones.
    #expect(UserDataLocations.isUnderTest)
}

@Test func everyDefaultLocationResolvesInsideTheTestSandbox() {
    let sandbox = UserDataLocations.testSandbox.standardizedFileURL.path
    let defaults: [(String, URL)] = [
        ("support directory", UserDataLocations.supportDirectory),
        ("routing config", SwitchyardConfigWriter.defaultConfigURL),
        ("active-route record", ActiveRoutingSessionStore.defaultURL),
        ("saved setup", SavedRoutingSetupStore.defaultURL),
        ("role library and groups", RoleLibraryStore.defaultURL),
        ("routing log", RoutingLogReader.defaultLogURL),
        ("diagnostics log", DiagnosticLog.defaultURL),
        ("shared diagnostics log", DiagnosticLog.shared.url),
        ("Codex config", CodexLocations.defaultConfigURL),
        ("Codex profile", CodexProfileWriter.defaultProfileURL),
        ("Codex setup", CodexSetupReader.defaultConfigURL),
    ]
    for (name, url) in defaults {
        let path = url.standardizedFileURL.path
        #expect(path.hasPrefix(sandbox), "\(name) escapes the sandbox: \(path)")
        #expect(!path.hasPrefix(realSupportDirectory.path), "\(name) points at the user's data: \(path)")
        #expect(!path.hasPrefix(realCodexDirectory.path), "\(name) points at the user's Codex: \(path)")
    }
}

/// The destructive paths, exercised rather than inspected: a model built the
/// way a careless test builds one must not touch anything outside the sandbox.
@MainActor
@Test func aDefaultConstructedModelOnlyEverTouchesTheSandbox() async throws {
    let liveCodexConfig = realCodexDirectory.appendingPathComponent("config.toml")
    let liveCodexProfile = realCodexDirectory.appendingPathComponent("switchyard-desktop.config.toml")
    let before = try? Data(contentsOf: liveCodexConfig)
    let liveProfile = try? Data(contentsOf: liveCodexProfile)
    let liveRecord = FileManager.default.fileExists(atPath: realSupportDirectory
        .appendingPathComponent("active-routing.json").path)
    let liveSetup = try? Data(contentsOf: realSupportDirectory
        .appendingPathComponent("saved-routing-setup.json"))

    // Loads the recovery record, may restore a configuration, may migrate and
    // save a setup — all of it against whatever the default stores resolve to.
    let model = WizardModel()
    await model.refreshCodexSelection()

    #expect(model.codexConfigPath.path.hasPrefix(UserDataLocations.testSandbox.path))
    #expect(model.codexProfilePath.path.hasPrefix(UserDataLocations.testSandbox.path))
    #expect(model.routingConfigPath.path.hasPrefix(UserDataLocations.testSandbox.path))
    #expect((try? Data(contentsOf: liveCodexConfig)) == before)
    #expect((try? Data(contentsOf: liveCodexProfile)) == liveProfile)
    #expect(FileManager.default.fileExists(atPath: realSupportDirectory
        .appendingPathComponent("active-routing.json").path) == liveRecord)
    #expect((try? Data(contentsOf: realSupportDirectory
        .appendingPathComponent("saved-routing-setup.json"))) == liveSetup)
}

/// `CODEX_HOME` still wins: the sandbox replaces the home directory a default
/// resolves under, not an explicit choice made by the environment or a caller.
@Test func anExplicitCodexHomeIsStillHonoured() {
    let explicit = CodexLocations.configURL(
        codexHome: "/somewhere/else", userHome: UserDataLocations.home
    )
    #expect(explicit.path == "/somewhere/else/config.toml")
    let explicitProfile = CodexLocations.profileURL(
        codexHome: "/somewhere/else", userHome: UserDataLocations.home
    )
    #expect(explicitProfile.path == "/somewhere/else/switchyard-desktop.config.toml")
}
