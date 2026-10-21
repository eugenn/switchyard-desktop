import Foundation
import Testing
@testable import SwitchyardDesktopKit

private func makeCodexSetupConfig(contents: String? = nil) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let config = directory.appendingPathComponent("config.toml")
    if let contents {
        try contents.write(to: config, atomically: true, encoding: .utf8)
    }
    return config
}

@Test func readerReadsOnlyRelevantNonSensitiveCodexSettings() throws {
    let config = try makeCodexSetupConfig(contents: """
    model = "gpt-5.6-codex"
    model_provider = "openai"
    api_key = "sk-test-secret-value"
    [projects."/Users/example/project"]
    trust_level = "trusted"
    """)
    defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

    let setup = try CodexSetupReader().read(configPath: config)

    #expect(setup.configPath == config)
    #expect(setup.model == "gpt-5.6-codex")
    #expect(setup.modelProvider == "openai")
}

@Test func readerAllowsOmittedModelSelections() throws {
    let config = try makeCodexSetupConfig(contents: "personality = \"pragmatic\"\n")
    defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

    let setup = try CodexSetupReader().read(configPath: config)

    #expect(setup.model == nil)
    #expect(setup.modelProvider == nil)
}

@Test func readerUsesDefaultsWithoutCreatingAMissingConfiguration() throws {
    let config = try makeCodexSetupConfig()
    defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

    let setup = try CodexSetupReader().read(configPath: config)
    #expect(setup.configPath == config)
    #expect(setup.model == nil)
    #expect(setup.modelProvider == nil)
    #expect(!FileManager.default.fileExists(atPath: config.path))
}

@Test func readerReportsAnUnreadableConfiguration() throws {
    let directory = try makeCodexSetupConfig().deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }

    do {
        _ = try CodexSetupReader().read(configPath: directory)
        Issue.record("Expected an unreadable configuration error.")
    } catch let failure as CodexSetupReader.Failure {
        #expect(failure == .unreadableConfiguration)
    }
}

@Test func readerRejectsMalformedTomlWithoutExposingCredentials() throws {
    let secret = "sk-this-secret-must-not-appear"
    let config = try makeCodexSetupConfig(contents: """
    api_key = "\(secret)"
    [unterminated
    """)
    defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

    do {
        _ = try CodexSetupReader().read(configPath: config)
        Issue.record("Expected a malformed configuration error.")
    } catch let failure as CodexSetupReader.Failure {
        #expect(failure == .malformedConfiguration)
        #expect(!(failure.errorDescription ?? "").contains(secret))
    }
}

@Test func readerRejectsAnEmptyModel() throws {
    let config = try makeCodexSetupConfig(contents: "model = \"   \"\n")
    defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

    do {
        _ = try CodexSetupReader().read(configPath: config)
        Issue.record("Expected an empty model error.")
    } catch let failure as CodexSetupReader.Failure {
        #expect(failure == .emptyField("model"))
    }
}

@Test func readerRejectsAnEmptyModelProvider() throws {
    let config = try makeCodexSetupConfig(contents: "model_provider = \"\"\n")
    defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

    do {
        _ = try CodexSetupReader().read(configPath: config)
        Issue.record("Expected an empty model provider error.")
    } catch let failure as CodexSetupReader.Failure {
        #expect(failure == .emptyField("model_provider"))
    }
}

@Test func readerRejectsNonStringRelevantFields() throws {
    let config = try makeCodexSetupConfig(contents: "model = 42\n")
    defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

    do {
        _ = try CodexSetupReader().read(configPath: config)
        Issue.record("Expected an invalid model type error.")
    } catch let failure as CodexSetupReader.Failure {
        #expect(failure == .invalidFieldType("model"))
    }
}

@Test func discoveryAndTheGeneratedProfileShareOneCodexHome() {
    #expect(CodexSetupReader.defaultConfigURL == CodexLocations.defaultConfigURL)
    #expect(
        CodexLocations.defaultProfileURL.deletingLastPathComponent()
            == CodexLocations.defaultConfigURL.deletingLastPathComponent()
    )
    let anotherUser = URL(fileURLWithPath: "/Users/another-person", isDirectory: true)
    #expect(CodexLocations.configURL(codexHome: nil, userHome: anotherUser).path
            == "/Users/another-person/.codex/config.toml")
    #expect(CodexLocations.configURL(codexHome: "/tmp/custom-codex", userHome: anotherUser).path
            == "/tmp/custom-codex/config.toml")
}
