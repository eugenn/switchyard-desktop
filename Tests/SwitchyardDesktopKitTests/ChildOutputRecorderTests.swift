import Foundation
import Testing
@testable import SwitchyardDesktopKit

private func recorderDirectory() -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Runs `/bin/sh -c script` with its output recorded, and waits for it to exit.
/// Returns whether it exited before the deadline.
@discardableResult
private func runRecorded(
    _ script: String,
    into recorder: ChildOutputRecorder,
    timeout: TimeInterval = 20
) async throws -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    recorder.begin(banner: "test run")
    process.standardOutput = recorder.pipe
    process.standardError = recorder.pipe
    try process.run()
    recorder.closeWriteEnd()

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        try await Task.sleep(for: .milliseconds(25))
    }
    let exited = !process.isRunning
    if !exited {
        process.terminate()
        process.waitUntilExit()
    }
    recorder.finish(banner: "test run finished")
    return exited
}

/// The reason this type exists: a pipe nobody reads holds about 64 KB, after
/// which the child blocks inside `write` and the proxy stops answering with no
/// record of why.
@Test(.timeLimit(.minutes(1)))
func aChildWritingFarMoreThanAPipeBufferIsNeverBlocked() async throws {
    let directory = recorderDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("switchyard-server.log")
    let recorder = ChildOutputRecorder(url: url)

    let exited = try await runRecorded(
        "i=0; while [ $i -lt 4000 ]; do echo \"served turn $i padding padding padding\"; i=$((i+1)); done; echo FINISHED",
        into: recorder
    )

    #expect(exited, "the child was still blocked writing to its pipe")
    let contents = try String(contentsOf: url, encoding: .utf8)
    #expect(contents.contains("FINISHED"))
    #expect(contents.contains("served turn 3999"))
}

@Test(.timeLimit(.minutes(1)))
func recordedOutputIsRedactedLineByLine() async throws {
    let directory = recorderDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("switchyard-server.log")
    let recorder = ChildOutputRecorder(url: url)

    try await runRecorded(
        "echo 'listening on 127.0.0.1:4100'; echo 'Cookie: session=process-secret'; echo 'ready'",
        into: recorder
    )

    let contents = try String(contentsOf: url, encoding: .utf8)
    #expect(!contents.contains("process-secret"))
    #expect(contents.contains(DiagnosticRedactor.placeholder))
    // One bad line must not cost the surrounding evidence.
    #expect(contents.contains("listening on 127.0.0.1:4100"))
    #expect(contents.contains("ready"))
    #expect(!recorder.recentText.contains("process-secret"))
}

@Test(.timeLimit(.minutes(1)))
func theInMemoryTailIsBoundedWhileTheFileKeepsEverything() async throws {
    let directory = recorderDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("switchyard-server.log")
    let recorder = ChildOutputRecorder(url: url)

    try await runRecorded(
        "i=0; while [ $i -lt 600 ]; do echo \"line $i padding padding padding padding\"; i=$((i+1)); done",
        into: recorder
    )

    #expect(recorder.recentText.count <= ChildOutputRecorder.memoryLimit)
    #expect(recorder.recentText.contains("line 599"))
    let contents = try String(contentsOf: url, encoding: .utf8)
    #expect(contents.contains("line 0 "))
}

@Test(.timeLimit(.minutes(1)))
func outputWithoutATrailingNewlineIsStillKept() async throws {
    let directory = recorderDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("switchyard-server.log")
    let recorder = ChildOutputRecorder(url: url)

    try await runRecorded("printf 'fatal: address already in use'", into: recorder)

    let contents = try String(contentsOf: url, encoding: .utf8)
    #expect(contents.contains("fatal: address already in use"))
}

@Test func eachRunIsBanneredSoTheFileSeparatesSessions() async throws {
    let directory = recorderDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("switchyard-server.log")

    try await runRecorded("echo one", into: ChildOutputRecorder(url: url))
    try await runRecorded("echo two", into: ChildOutputRecorder(url: url))

    let contents = try String(contentsOf: url, encoding: .utf8)
    #expect(contents.components(separatedBy: "=== ").count == 5)
    #expect(contents.contains("one"))
    #expect(contents.contains("two"))
}
