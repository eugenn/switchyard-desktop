import Foundation
import Testing
@testable import SwitchyardDesktopKit

private func temporaryDirectory() -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func anEventIsRecordedAsOneGreppableLine() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = DiagnosticLog(url: directory.appendingPathComponent("diagnostics.log"))

    log.error("proxy", "switchyard-server stopped unexpectedly", [("exit", "1"), ("port", "4100")])

    let lines = log.recentText().split(separator: "\n")
    #expect(lines.count == 1)
    let line = try #require(lines.first.map(String.init))
    #expect(line.contains("ERROR [proxy] switchyard-server stopped unexpectedly"))
    #expect(line.contains("exit=1 port=4100"))
    // The line starts with a sortable timestamp, so the file reads in order.
    #expect(line.hasPrefix("2"))
}

@Test func theLogNeverRetainsCredentialsOrRequestContent() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = DiagnosticLog(url: directory.appendingPathComponent("diagnostics.log"))

    log.info("proxy", "Authorization: Bearer abc123def456", [("error", "api_key=sk-live-9f8e7d6c5b4a3210")])
    log.appendDetail("Cookie: session=super-secret-value\nmessages: [the user's prompt]")

    let text = log.recentText()
    #expect(!text.contains("abc123def456"))
    #expect(!text.contains("sk-live-9f8e7d6c5b4a3210"))
    #expect(!text.contains("super-secret-value"))
    #expect(!text.contains("the user's prompt"))
    #expect(text.contains(DiagnosticRedactor.placeholder))
}

@Test func aMultiLineDetailCannotForgeFurtherEvents() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = DiagnosticLog(url: directory.appendingPathComponent("diagnostics.log"))

    log.error("proxy", "exited", [("error", "first line\nsecond line")])
    log.appendDetail("traceback line one\ntraceback line two")

    let lines = log.recentText().split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.count == 3)
    #expect(lines[0].contains("first line second line"))
    // Detail lines are indented, so only events start at column zero.
    #expect(lines[1].hasPrefix("    traceback line one"))
    #expect(lines[2].hasPrefix("    traceback line two"))
}

@Test func theLogRotatesOnceItPassesItsLimitAndKeepsOneGeneration() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("diagnostics.log")
    let previous = DiagnosticFile.previousURL(for: url)

    // Written directly, so the test does not depend on the production limit.
    let line = String(repeating: "x", count: 200) + "\n"
    for _ in 0..<10 {
        DiagnosticFile.append(line, to: url, byteLimit: 1_000)
    }

    #expect(FileManager.default.fileExists(atPath: previous.path))
    // Rotation happens before a write, so the file can end one line past the
    // limit and never further.
    let current = try String(contentsOf: url, encoding: .utf8)
    #expect(current.count < 1_000 + line.count)
    #expect(previous.lastPathComponent == "diagnostics.previous.log")
}

@Test func readingTheTailDropsThePartialLineTheOffsetCutsThrough() {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("diagnostics.log")

    DiagnosticFile.append("first event\nsecond event\nthird event\n", to: url, byteLimit: 1_000_000)

    let tail = DiagnosticFile.tail(of: url, byteLimit: 20)
    #expect(!tail.contains("first event"))
    #expect(tail.contains("third event"))
}

@Test func companionFilesSitBesideTheLog() {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = DiagnosticLog(url: directory.appendingPathComponent("diagnostics.log"))

    #expect(
        log.companionURL(named: "switchyard-server.log").deletingLastPathComponent().path
            == directory.path
    )
}

@Test func theDefaultLogLivesInTheDirectoryThisAppOwns() {
    #expect(
        DiagnosticLog.defaultURL.deletingLastPathComponent().standardizedFileURL
            == SwitchyardConfigWriter.supportDirectory.standardizedFileURL
    )
    #expect(DiagnosticLog.defaultURL.lastPathComponent == "diagnostics.log")
}

/// Regression: the first version of this guard read an environment variable
/// that `swift test` does not always set, and the suite appended its own noise
/// to the log a real incident is read back from. The guard now lives in
/// `UserDataLocations`, which moves the whole directory — so the shared log is
/// simply the default one, and the default one is inside the sandbox.
@Test func aTestRunNeverWritesToTheLogTheUserReadsBack() {
    #expect(DiagnosticLog.isUnderTest)
    #expect(DiagnosticLog.shared.url.standardizedFileURL == DiagnosticLog.defaultURL.standardizedFileURL)
    #expect(DiagnosticLog.shared.url.path.hasPrefix(UserDataLocations.testSandbox.path))
}
