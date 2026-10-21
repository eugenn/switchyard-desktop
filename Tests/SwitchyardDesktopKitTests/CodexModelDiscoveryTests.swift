import Foundation
import Testing
@testable import SwitchyardDesktopKit

private func sampleCodexSetup() -> CodexSetup {
    CodexSetup(
        configPath: URL(fileURLWithPath: "/tmp/switchyard-desktop-codex/config.toml"),
        model: "gpt-5.6-sol",
        modelProvider: "openai"
    )
}

private func appServerOutput(
    models: [[String: Any]],
    nextCursor: String? = nil
) throws -> Data {
    let initialize = try JSONSerialization.data(withJSONObject: ["id": 1, "result": [:]])
    var modelListResult: [String: Any] = ["data": models]
    if let nextCursor {
        modelListResult["nextCursor"] = nextCursor
    }
    let result = try JSONSerialization.data(withJSONObject: [
        "id": 2,
        "result": modelListResult,
    ])
    return initialize + Data([0x0A]) + result + Data([0x0A])
}

/// The discovery closure is `@Sendable`, so what it observed is recorded in a
/// lock-guarded box rather than in captured `var`s.
private final class ExchangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest = ""
    private var storedEnvironment: [String: String] = [:]

    var request: String {
        lock.lock(); defer { lock.unlock() }
        return storedRequest
    }

    var environment: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return storedEnvironment
    }

    func record(request: String, environment: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        storedRequest = request
        storedEnvironment = environment
    }
}

@Test func discoveryUsesTheAuthenticatedAppServerModelList() throws {
    let recorder = ExchangeRecorder()
    let discovery = CodexModelDiscovery { input, environment in
        recorder.record(
            request: String(decoding: input, as: UTF8.self),
            environment: environment
        )
        return CodexModelDiscovery.CommandOutput(
            stdout: try appServerOutput(models: [
                [
                    "id": "gpt-5.6-sol",
                    "model": "gpt-5.6-sol",
                    "displayName": "GPT-5.6 Sol",
                    "hidden": false,
                    "isDefault": true,
                ],
                [
                    "id": "gpt-5.6-terra",
                    "model": "gpt-5.6-terra",
                    "displayName": "GPT-5.6 Terra",
                    "hidden": false,
                    "isDefault": false,
                ],
            ]),
            stderr: Data(),
            exitStatus: 0
        )
    }

    let models = try discovery.discover(using: sampleCodexSetup())

    #expect(models == [
        CodexSubscriptionModel(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", isDefault: true),
        CodexSubscriptionModel(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra", isDefault: false),
    ])
    #expect(recorder.request.contains("\"method\":\"initialize\""))
    #expect(recorder.request.contains("\"method\":\"initialized\""))
    // JSONSerialization escapes the path separator: "method":"model\/list".
    #expect(recorder.request.contains("\"method\":\"model\\/list\""))
    #expect(recorder.request.contains("\"includeHidden\":false"))
    #expect(recorder.environment["CODEX_HOME"] == "/tmp/switchyard-desktop-codex")
}

@Test func discoveryExcludesHiddenInvalidAndDuplicateModels() throws {
    let discovery = CodexModelDiscovery { _, _ in
        CodexModelDiscovery.CommandOutput(
            stdout: try appServerOutput(models: [
                ["model": "gpt-5.6-sol", "hidden": false],
                ["model": "gpt-5.6-sol", "hidden": false],
                ["model": "gpt-hidden", "hidden": true],
                ["model": "   ", "hidden": false],
                ["id": "gpt-5.6-terra", "hidden": false],
            ]),
            stderr: Data(),
            exitStatus: 0
        )
    }

    let models = try discovery.discover(using: sampleCodexSetup())

    #expect(models.map(\.id) == ["gpt-5.6-sol", "gpt-5.6-terra"])
}

@Test func discoveryPreservesActionableMissingCLIErrors() throws {
    let discovery = CodexModelDiscovery { _, _ in throw CodexModelDiscovery.Failure.codexUnavailable }
    #expect(throws: CodexModelDiscovery.Failure.codexUnavailable) {
        try discovery.discover(using: sampleCodexSetup())
    }
}

@Test func discoveryDoesNotSilentlyAcceptAnIncompletePage() throws {
    let discovery = CodexModelDiscovery { _, _ in
        CodexModelDiscovery.CommandOutput(
            stdout: try appServerOutput(
                models: [["model": "gpt-5.6-sol", "hidden": false]],
                nextCursor: "more"
            ),
            stderr: Data(),
            exitStatus: 0
        )
    }

    do {
        _ = try discovery.discover(using: sampleCodexSetup())
        Issue.record("Expected an incomplete result error.")
    } catch let failure as CodexModelDiscovery.Failure {
        #expect(failure == .incompleteResult)
    }
}

@Test func discoveryReportsAnEmptyModelListWithoutUsingAStaticFallback() throws {
    let discovery = CodexModelDiscovery { _, _ in
        CodexModelDiscovery.CommandOutput(
            stdout: try appServerOutput(models: []),
            stderr: Data(),
            exitStatus: 0
        )
    }

    do {
        _ = try discovery.discover(using: sampleCodexSetup())
        Issue.record("Expected an empty model list error.")
    } catch let failure as CodexModelDiscovery.Failure {
        #expect(failure == .noModels)
    }
}

@Test func discoveryCategorizesAuthenticationFailuresWithoutExposingSecrets() throws {
    let secret = "sk-discovery-secret-must-not-appear"
    let discovery = CodexModelDiscovery { _, _ in
        CodexModelDiscovery.CommandOutput(
            stdout: Data(),
            stderr: Data("Unauthorized: \(secret)".utf8),
            exitStatus: 1
        )
    }

    do {
        _ = try discovery.discover(using: sampleCodexSetup())
        Issue.record("Expected an unauthenticated error.")
    } catch let failure as CodexModelDiscovery.Failure {
        #expect(failure == .unauthenticated)
        #expect(!(failure.errorDescription ?? "").contains(secret))
    }
}

@Test func discoveryCategorizesAMissingCodexCli() throws {
    let discovery = CodexModelDiscovery { _, _ in
        CodexModelDiscovery.CommandOutput(
            stdout: Data(),
            stderr: Data("codex: command not found".utf8),
            exitStatus: 127
        )
    }

    do {
        _ = try discovery.discover(using: sampleCodexSetup())
        Issue.record("Expected a missing Codex CLI error.")
    } catch let failure as CodexModelDiscovery.Failure {
        #expect(failure == .codexUnavailable)
    }
}
