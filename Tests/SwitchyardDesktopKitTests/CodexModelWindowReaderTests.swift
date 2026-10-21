import Foundation
import Testing
@testable import SwitchyardDesktopKit

private func catalog(_ models: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["models": models])
}

private func reader(
    stdout: Data,
    exitStatus: Int32 = 0,
    onRun: (@Sendable ([String: String]) -> Void)? = nil
) -> CodexModelWindowReader {
    CodexModelWindowReader { environment in
        onRun?(environment)
        return CodexModelWindowReader.CommandOutput(stdout: stdout, exitStatus: exitStatus)
    }
}

private func sampleCodexSetup() -> CodexSetup {
    CodexSetup(
        configPath: URL(fileURLWithPath: "/tmp/switchyard-desktop-codex/config.toml"),
        model: "gpt-5.6-sol",
        modelProvider: "openai"
    )
}

@Test func readsMaximumWindowPerModel() throws {
    let data = try catalog([
        ["slug": "gpt-5.6-sol", "context_window": 272_000, "max_context_window": 872_000],
        ["slug": "gpt-5.5", "context_window": 272_000, "max_context_window": 272_000],
    ])
    let windows = try reader(stdout: data).windows(using: nil)

    #expect(windows["gpt-5.6-sol"]?.largest == 872_000)
    #expect(windows["gpt-5.5"]?.largest == 272_000)
}

/// Codex's default window is not its ceiling, so a catalog that names only the
/// default still yields a usable number rather than nothing.
@Test func fallsBackToTheDefaultWindowWhenNoMaximumIsNamed() throws {
    let data = try catalog([["slug": "gpt-5.2", "context_window": 272_000]])
    let windows = try reader(stdout: data).windows(using: nil)

    #expect(windows["gpt-5.2"]?.largest == 272_000)
}

@Test func skipsEntriesWithNoUsableWindow() throws {
    let data = try catalog([
        ["slug": "gpt-5.6-sol", "max_context_window": 872_000],
        ["slug": "no-window"],
        ["slug": "zero-window", "context_window": 0, "max_context_window": 0],
        ["slug": "  ", "max_context_window": 872_000],
    ])
    let windows = try reader(stdout: data).windows(using: nil)

    #expect(windows.keys.sorted() == ["gpt-5.6-sol"])
}

@Test func rejectsACatalogWithNoReadableModel() throws {
    #expect(throws: CodexModelWindowReader.Failure.invalidResponse) {
        try reader(stdout: try catalog([["slug": "no-window"]])).windows(using: nil)
    }
}

@Test func rejectsOutputThatIsNotACatalog() {
    #expect(throws: CodexModelWindowReader.Failure.invalidResponse) {
        try reader(stdout: Data("not json".utf8)).windows(using: nil)
    }
}

@Test func reportsAFailedCommand() throws {
    let data = try catalog([["slug": "gpt-5.6-sol", "max_context_window": 872_000]])
    #expect(throws: CodexModelWindowReader.Failure.commandFailed) {
        try reader(stdout: data, exitStatus: 1).windows(using: nil)
    }
}

/// The catalog has to come from the account the rest of the app reads, not from
/// whichever `CODEX_HOME` the app process happens to have inherited.
@Test func runsAgainstTheSetupsCodexHome() throws {
    let recorded = Recorder()
    let data = try catalog([["slug": "gpt-5.6-sol", "max_context_window": 872_000]])
    _ = try reader(stdout: data, onRun: { recorded.store($0) }).windows(using: sampleCodexSetup())

    #expect(recorded.environment["CODEX_HOME"] == "/tmp/switchyard-desktop-codex")
}

/// The run closure is `@Sendable`, so what it saw is kept under a lock.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String] = [:]

    var environment: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func store(_ environment: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        stored = environment
    }
}
