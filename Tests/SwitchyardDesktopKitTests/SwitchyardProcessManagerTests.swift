import Foundation
import Testing
@testable import SwitchyardDesktopKit

private let testPort = 4100

private func sampleProfile() -> RoutingProfile {
    RoutingProfile(
        provider: .codex,
        algorithm: .stageRouter,
        tiers: [
            TaskTier(name: "Efficient", summary: "Simple.", modelID: "gpt-5.3-codex-spark"),
            TaskTier(name: "Capable", summary: "Complex.", modelID: "gpt-6-astra"),
        ],
        port: testPort
    )
}

/// Writes a valid generated config into a fresh temp directory.
private func writeSampleConfig() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let target = directory.appendingPathComponent("routes.toml")
    try SwitchyardConfigWriter.write(profile: sampleProfile(), to: target)
    return target
}

@MainActor
@Test func startRefusesTheReservedPort() async throws {
    let manager = SwitchyardProcessManager()
    let config = try writeSampleConfig()
    defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

    await #expect(throws: SwitchyardProcessManager.Failure.reservedPort(4000)) {
        try await manager.start(
            configPath: config,
            binaryPath: URL(fileURLWithPath: "/bin/sh"),
            port: RoutingProfile.reservedPort
        )
    }
    #expect(manager.status == .stopped)
}

@MainActor
@Test func startRefusesAMissingBinary() async throws {
    let manager = SwitchyardProcessManager()
    let config = try writeSampleConfig()
    defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
    let missing = "/nonexistent/switchyard-server"

    await #expect(throws: SwitchyardProcessManager.Failure.binaryNotExecutable(missing)) {
        try await manager.start(configPath: config, binaryPath: URL(fileURLWithPath: missing))
    }
}

@MainActor
@Test func aProcessThatExitsImmediatelyIsReportedAsFailed() async throws {
    let manager = SwitchyardProcessManager()
    let config = try writeSampleConfig()
    defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

    // /usr/bin/false ignores the arguments and exits non-zero right away.
    await #expect(throws: SwitchyardProcessManager.Failure.self) {
        try await manager.start(
            configPath: config,
            binaryPath: URL(fileURLWithPath: "/usr/bin/false"),
            port: testPort
        )
    }
    #expect(!manager.status.isRunning)
    #expect(manager.status != .stopped)
}

@MainActor
@Test func processManagerDoesNotRetainUnredactedSubprocessOutput() async throws {
    // A longer grace period than the default: under parallel test load the
    // helper script can take more than 400 ms just to start and exit.
    let manager = SwitchyardProcessManager(startupGracePeriod: .milliseconds(2_000))
    let config = try writeSampleConfig()
    let binary = try writeDiagnosticServer(
        in: config.deletingLastPathComponent(),
        output: "Cookie: session=process-secret"
    )
    defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }

    await #expect(throws: SwitchyardProcessManager.Failure.self) {
        try await manager.start(configPath: config, binaryPath: binary, port: testPort)
    }

    #expect(!manager.lastOutput.contains("process-secret"))
    #expect(manager.lastOutput.contains(DiagnosticRedactor.placeholder))
}

@MainActor
@Test func stopIsSafeWhenNothingIsRunning() {
    let manager = SwitchyardProcessManager()
    manager.stop()
    #expect(manager.status == .stopped)
}

@MainActor
@Test func startsAndStopsTheRealProxyOnPort4100() async throws {
    guard let binary = SwitchyardBinaryLocator.locate() else { return }
    guard !isPortInUse(testPort) else { return }

    let manager = SwitchyardProcessManager()
    let config = try writeSampleConfig()
    defer {
        manager.stop()
        try? FileManager.default.removeItem(at: config.deletingLastPathComponent())
    }

    try await manager.start(configPath: config, binaryPath: binary, port: testPort)
    #expect(manager.status.isRunning)
    #expect(manager.status == .running(pid: manager.runningPID ?? -1, port: testPort))
    #expect(isPortInUse(testPort))

    // Starting twice is refused rather than leaking a second process.
    await #expect(throws: SwitchyardProcessManager.Failure.alreadyRunning) {
        try await manager.start(configPath: config, binaryPath: binary, port: testPort)
    }

    manager.stop()
    #expect(manager.status == .stopped)
    try await Task.sleep(for: .milliseconds(300))
    #expect(!isPortInUse(testPort))
}

/// Guards the constraint from tasks.md 4.3: nothing in the app may default to port 4000.
@Test func noCodePathDefaultsToTheReservedPort() {
    #expect(RoutingProfile.defaultPort != RoutingProfile.reservedPort)
    #expect(RoutingProfile().port == 4100)
}

// MARK: - Helpers

private func isPortInUse(_ port: Int) -> Bool {
    let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard socketDescriptor >= 0 else { return false }
    defer { close(socketDescriptor) }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")

    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return result == 0
}

private func writeDiagnosticServer(in directory: URL, output: String) throws -> URL {
    let script = directory.appendingPathComponent("diagnostic-server.sh")
    let escapedOutput = output.replacingOccurrences(of: "'", with: "'\\''")
    try "#!/bin/sh\nprintf '%s\\n' '\(escapedOutput)'\nexit 1\n"
        .write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    return script
}

@MainActor
@Test func serverExitAfterStartupBecomesARecoverableFailure() async throws {
    let config = try writeSampleConfig()
    let directory = config.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let binary = directory.appendingPathComponent("short-lived-server")
    // Long enough that a loaded machine still sees it running once the grace
    // period is over, so this exercises the monitor and not startup.
    try "#!/bin/sh\nexec /bin/sleep 4\n".write(to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    let manager = SwitchyardProcessManager(startupGracePeriod: .milliseconds(200))
    defer { manager.stop() }
    try await manager.start(configPath: config, binaryPath: binary, port: 4199)
    #expect(manager.status.isRunning)
    let deadline = Date().addingTimeInterval(15)
    while manager.status.isRunning && Date() < deadline {
        try await Task.sleep(for: .milliseconds(100))
    }
    guard case .failed(let message) = manager.status else {
        Issue.record("An exited server was still shown as running")
        return
    }
    #expect(message.contains("Stop routing"))
}

@MainActor
@Test func aServerThatExitsDuringStartupIsExplainedInTheDurableLog() async throws {
    let config = try writeSampleConfig()
    let directory = config.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = DiagnosticLog(url: directory.appendingPathComponent("diagnostics.log"))
    let binary = try writeDiagnosticServer(
        in: directory,
        output: "fatal: could not bind 127.0.0.1:4100"
    )
    let manager = SwitchyardProcessManager(
        startupGracePeriod: .milliseconds(2_000),
        diagnostics: log
    )

    await #expect(throws: SwitchyardProcessManager.Failure.self) {
        try await manager.start(configPath: config, binaryPath: binary, port: testPort)
    }

    let events = log.recentText()
    #expect(events.contains("Starting switchyard-server"))
    #expect(events.contains("exited during startup"))
    #expect(events.contains("exit=1"))
    // The server's own account of the failure outlives the session as well.
    let serverLog = try String(contentsOf: manager.serverLogURL, encoding: .utf8)
    #expect(serverLog.contains("fatal: could not bind 127.0.0.1:4100"))
    #expect(manager.serverLogURL.deletingLastPathComponent().path == directory.path)
}

@MainActor
@Test func aDeliberateStopIsRecordedSeparatelyFromAnUnexpectedOne() async throws {
    let config = try writeSampleConfig()
    let directory = config.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = DiagnosticLog(url: directory.appendingPathComponent("diagnostics.log"))
    let binary = directory.appendingPathComponent("idle-server")
    try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    let manager = SwitchyardProcessManager(startupGracePeriod: .milliseconds(200), diagnostics: log)

    try await manager.start(configPath: config, binaryPath: binary, port: 4198)
    manager.stop()

    let events = log.recentText()
    #expect(events.contains("switchyard-server is running"))
    #expect(events.contains("switchyard-server stopped"))
    #expect(events.contains("reason=requested"))
    #expect(!events.contains("stopped unexpectedly"))
}

@MainActor
@Test func anUnexpectedExitIsRecordedWithWhatTheServerLastPrinted() async throws {
    let config = try writeSampleConfig()
    let directory = config.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = DiagnosticLog(url: directory.appendingPathComponent("diagnostics.log"))
    let binary = directory.appendingPathComponent("short-lived-server")
    // Long enough that a loaded machine still sees it running once the grace
    // period is over, so the test exercises the monitor and not startup.
    try "#!/bin/sh\nsleep 4\necho 'panic: upstream connection reset'\nexit 7\n"
        .write(to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    let manager = SwitchyardProcessManager(startupGracePeriod: .milliseconds(200), diagnostics: log)
    defer { manager.stop() }

    try await manager.start(configPath: config, binaryPath: binary, port: 4197)
    let deadline = Date().addingTimeInterval(15)
    while manager.status.isRunning && Date() < deadline {
        try await Task.sleep(for: .milliseconds(100))
    }

    let events = log.recentText()
    #expect(events.contains("switchyard-server stopped unexpectedly while routing was active"))
    #expect(events.contains("exit=7"))
    #expect(events.contains("panic: upstream connection reset"))
}
