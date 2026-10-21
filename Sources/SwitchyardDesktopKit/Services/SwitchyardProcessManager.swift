import Darwin
import Foundation
import Observation

/// Owns the `switchyard-server` child process for the lifetime of the app.
///
/// The server's own default port is 4000, which a separate long-running
/// experiment on this machine already owns — this manager always passes an
/// explicit `--port` and refuses to start on the reserved one.
///
/// Everything the proxy does is recorded: its own output goes to a durable
/// file through `ChildOutputRecorder`, and every lifecycle event — start,
/// stop, an unexpected exit, a health probe that stops answering — goes to the
/// app's `DiagnosticLog`. A route that dies while the user is in Codex is
/// noticed there and not here, so the evidence has to outlive the session.
@MainActor
@Observable
package final class SwitchyardProcessManager {
    package enum Status: Equatable {
        case stopped
        case running(pid: Int32, port: Int)
        case failed(String)

        package var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    package enum Failure: LocalizedError, Equatable {
        case alreadyRunning
        case reservedPort(Int)
        case binaryNotExecutable(String)
        case launchFailed(String)
        case exitedImmediately(status: Int32, output: String)

        package var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return "The proxy is already running. Stop it before starting it again."
            case .reservedPort(let port):
                return "Port \(port) is reserved by another Switchyard instance and cannot be used."
            case .binaryNotExecutable(let path):
                return "switchyard-server is not executable at \(path)."
            case .launchFailed(let reason):
                return "Could not start switchyard-server: \(reason)"
            case .exitedImmediately(let status, let output):
                let detail = output.isEmpty ? "exit code \(status)" : output
                return "switchyard-server stopped right after starting:\n\(detail)"
            }
        }
    }

    package private(set) var status: Status = .stopped
    /// Most recent output from the child process, for surfacing failures in the UI.
    package private(set) var lastOutput: String = ""
    /// Loopback host and routing-log path of the running process, for the
    /// statistics window's own reads.
    package private(set) var host: String = RoutingProfile.defaultHost
    package private(set) var routingLogPath: URL?

    /// PID of the managed process, if one is running.
    package var runningPID: Int32? {
        if case .running(let pid, _) = status { return pid }
        return nil
    }

    package let liteLLM: LiteLLMProcessManager

    /// Where this manager keeps the proxy's own stdout and stderr.
    package var serverLogURL: URL { diagnostics.companionURL(named: "switchyard-server.log") }

    private var process: Process?
    private var recorder: ChildOutputRecorder?
    private var monitorTask: Task<Void, Never>?
    private let registry: any ManagedProcessRecording
    private let reclaimer: LeftoverProcessReclaimer

    /// How long to wait before deciding the process survived startup.
    private let startupGracePeriod: Duration
    private let beforeStop: (() -> Void)?
    private let diagnostics: DiagnosticLog
    private let healthClient = SwitchyardStatsClient(timeout: 3)

    /// Seconds between liveness probes of the running proxy. A process that is
    /// alive but no longer answering is invisible to a `isRunning` check and is
    /// exactly what a user sees as "the router disappeared from Codex".
    private static let healthProbeInterval = 30

    /// How long a stopping server may take before it is killed. Terminating
    /// without a bound is what turns "Stop" into a beachball.
    private let terminationTimeout: TimeInterval

    package init(
        startupGracePeriod: Duration = .milliseconds(400),
        beforeStop: (() -> Void)? = nil,
        diagnostics: DiagnosticLog = .shared,
        registry: any ManagedProcessRecording = ManagedProcessRegistry.standard(),
        reclaimer: LeftoverProcessReclaimer = LeftoverProcessReclaimer(),
        terminationTimeout: TimeInterval = 3
    ) {
        self.terminationTimeout = terminationTimeout
        self.startupGracePeriod = startupGracePeriod
        self.beforeStop = beforeStop
        self.diagnostics = diagnostics
        self.registry = registry
        self.reclaimer = reclaimer
        self.liteLLM = LiteLLMProcessManager(diagnostics: diagnostics, registry: registry)
    }

    /// Stops servers left behind by a run that never reached its own shutdown —
    /// a crash, a Force Quit, a log-out — and reports what could not be freed.
    ///
    /// Called before every readiness check and again before Apply, because the
    /// leftover is invisible to the user: all they see is a port in use and a
    /// Start button that stays disabled until they open a terminal.
    @discardableResult
    package func reclaimLeftovers(
        host: String = RoutingProfile.defaultHost,
        port: Int? = nil,
        binaryPath: URL? = nil
    ) async -> LeftoverReclaimReport {
        guard !status.isRunning else { return LeftoverReclaimReport() }
        var report = LeftoverReclaimReport()
        let live = Set([runningPID, liteLLM.runningPID].compactMap { $0 })

        for (record, outcome) in await reclaimer.reclaim(records: registry.records(), excluding: live) {
            report.add(outcome, port: record.port)
            if outcome.clearsRecord { registry.forget(pid: record.pid) }
        }

        // A build before this record existed, or a support file someone
        // deleted, leaves only the socket to go by.
        if let port, !RoutingReadinessChecker.isPortAvailable(host: host, port: port) {
            let owned = [binaryPath?.path, SwitchyardBinaryLocator.locate(explicitPath: "")?.path]
                .compactMap { $0 }
            for outcome in await reclaimer.reclaimPort(
                port, name: "switchyard-server", ownedExecutables: owned, excluding: live
            ) {
                report.add(outcome, port: port)
            }
        }
        if !RoutingReadinessChecker.isPortAvailable(host: "127.0.0.1", port: LiteLLMProcessManager.port),
           let runtime = LiteLLMProcessManager.runtimeURL {
            for outcome in await reclaimer.reclaimPort(
                LiteLLMProcessManager.port,
                name: "LiteLLM",
                ownedExecutables: [runtime.appendingPathComponent("bin/python3.12").path],
                excluding: live
            ) {
                report.add(outcome, port: LiteLLMProcessManager.port)
            }
        }

        if report.freedSomething {
            if let port { _ = await reclaimer.waitForPortToClear(host: host, port: port) }
            _ = await reclaimer.waitForPortToClear(host: "127.0.0.1", port: LiteLLMProcessManager.port)
        }
        for line in report.reclaimed {
            diagnostics.warning("proxy", "Stopped a server left by an earlier run", [("detail", line)])
        }
        for line in report.blocked {
            diagnostics.warning("proxy", "A port this app needs is held by another process", [("detail", line)])
        }
        return report
    }

    /// Launches the proxy and confirms it is still alive after a short grace period.
    ///
    /// `routingLogPath` is where the server appends its durable per-request
    /// routing records; the statistics window reads that file back.
    package func start(
        configPath: URL,
        binaryPath: URL,
        host: String = RoutingProfile.defaultHost,
        port: Int = RoutingProfile.defaultPort,
        routingLogPath: URL? = nil,
        liteLLMModels: [LiteLLMModel]? = nil
    ) async throws {
        guard !status.isRunning else { throw Failure.alreadyRunning }
        guard port != RoutingProfile.reservedPort else {
            diagnostics.error("proxy", "Refused to start on the reserved port", [("port", String(port))])
            throw Failure.reservedPort(port)
        }
        guard FileManager.default.isExecutableFile(atPath: binaryPath.path) else {
            diagnostics.error("proxy", "switchyard-server is not executable", [("binary", binaryPath.path)])
            throw Failure.binaryNotExecutable(binaryPath.path)
        }

        diagnostics.info("proxy", "Starting switchyard-server", [
            ("binary", binaryPath.path),
            ("config", configPath.path),
            ("host", host),
            ("port", String(port)),
            ("upstream", liteLLMModels == nil ? "external" : "managed-litellm"),
        ])

        if let liteLLMModels {
            do {
                try await liteLLM.start(models: liteLLMModels)
            } catch {
                diagnostics.error("proxy", "LiteLLM did not start, so the proxy was not started", [
                    ("error", error.localizedDescription)
                ])
                throw error
            }
        }
        var started = false
        defer { if !started { liteLLM.stop() } }

        let process = Process()
        process.executableURL = binaryPath
        var arguments = [
            "--config", configPath.path,
            "--host", host,
            "--port", String(port)
        ]
        if let routingLogPath {
            try? FileManager.default.createDirectory(
                at: routingLogPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            arguments += ["--routing-log-file", routingLogPath.path]
        }
        process.arguments = arguments
        // Draining continuously matters as much as keeping the output: an
        // unread pipe fills at about 64 KB and blocks the server mid-write.
        let recorder = ChildOutputRecorder(url: serverLogURL)
        recorder.begin(banner: "switchyard-server starting on \(host):\(port)")
        process.standardOutput = recorder.pipe
        process.standardError = recorder.pipe

        do {
            try process.run()
        } catch {
            recorder.finish(banner: "switchyard-server could not be launched")
            let reason = DiagnosticRedactor.redact(error.localizedDescription)
            diagnostics.error("proxy", "switchyard-server could not be launched", [("error", reason)])
            status = .failed(reason)
            throw Failure.launchFailed(reason)
        }
        // The child owns its own copy now; keeping ours open would hide the
        // end of its output from the recorder.
        recorder.closeWriteEnd()

        self.process = process
        self.recorder = recorder
        lastOutput = ""
        // Recorded before the grace period, not after: a crash inside those
        // milliseconds still leaves a child holding the port.
        registry.record(
            ManagedProcessRecord(
                name: "switchyard-server",
                pid: process.processIdentifier,
                port: port,
                executablePath: binaryPath.standardizedFileURL.path,
                startedAt: Date()
            )
        )

        try? await Task.sleep(for: startupGracePeriod)

        guard process.isRunning else {
            let exitStatus = process.terminationStatus
            recorder.finish(banner: "switchyard-server exited during startup")
            let output = recorder.recentText
            lastOutput = output
            registry.forget(pid: process.processIdentifier)
            self.process = nil
            self.recorder = nil
            diagnostics.error("proxy", "switchyard-server exited during startup", [
                ("exit", String(exitStatus)),
                ("port", String(port)),
                ("log", serverLogURL.path),
            ])
            diagnostics.appendDetail(output)
            status = .failed(output.isEmpty ? "exit code \(exitStatus)" : output)
            throw Failure.exitedImmediately(status: exitStatus, output: output)
        }

        status = .running(pid: process.processIdentifier, port: port)
        self.host = host
        self.routingLogPath = routingLogPath
        started = true
        diagnostics.info("proxy", "switchyard-server is running", [
            ("pid", String(process.processIdentifier)),
            ("port", String(port)),
            ("log", serverLogURL.path),
        ])
        let managesLiteLLM = liteLLMModels != nil
        monitorTask = Task { [weak self, weak process] in
            var secondsSinceProbe = 0
            var healthFailures = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, let process else { return }
                if !process.isRunning {
                    self.reportUnexpectedExit(
                        "switchyard-server",
                        exitStatus: process.terminationStatus,
                        wasSignalled: process.terminationReason == .uncaughtSignal
                    )
                    return
                }
                if managesLiteLLM && !self.liteLLM.isRunning {
                    self.reportUnexpectedExit("LiteLLM", exitStatus: nil, wasSignalled: false)
                    return
                }

                secondsSinceProbe += 1
                guard secondsSinceProbe >= Self.healthProbeInterval else { continue }
                secondsSinceProbe = 0
                if await self.isAnswering(port: port) {
                    if healthFailures > 0 {
                        self.diagnostics.info("proxy", "switchyard-server is answering again", [
                            ("port", String(port)),
                            ("missedProbes", String(healthFailures)),
                        ])
                    }
                    healthFailures = 0
                } else {
                    healthFailures += 1
                    // Every probe once it starts failing would be noise; the
                    // first and then one a minute keep the outage bounded in time.
                    if healthFailures == 1 || healthFailures % 2 == 0 {
                        self.diagnostics.warning(
                            "proxy",
                            "switchyard-server is running but not answering its statistics endpoint",
                            [
                                ("pid", String(process.processIdentifier)),
                                ("port", String(port)),
                                ("missedProbes", String(healthFailures)),
                            ]
                        )
                    }
                }
            }
        }
    }

    /// Terminates the proxy if this app started it. Safe to call when already stopped.
    package func stop() {
        stop(reason: "requested")
    }

    private func stop(reason: String) {
        monitorTask?.cancel()
        monitorTask = nil
        defer { liteLLM.stop() }
        let pid = process?.processIdentifier
        var forced = false
        if let process, process.isRunning {
            beforeStop?()
            process.terminate()
            let deadline = Date().addingTimeInterval(terminationTimeout)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            // A server that ignores SIGTERM would otherwise keep its port and
            // block the next start, with this call blocked on it forever.
            if process.isRunning {
                forced = true
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
        }
        if let pid { registry.forget(pid: pid) }
        if let recorder {
            recorder.finish(banner: "switchyard-server stopped (\(reason))")
            let output = recorder.recentText
            if !output.isEmpty { lastOutput = output }
        }
        if let pid {
            diagnostics.info("proxy", "switchyard-server stopped", [
                ("pid", String(pid)),
                ("reason", reason),
                ("signal", forced ? "SIGKILL" : "SIGTERM"),
            ])
        }
        process = nil
        recorder = nil
        status = .stopped
    }

    /// A managed server that disappears while routing is active leaves Codex
    /// pointing at a dead endpoint, which is what the user sees. Record what
    /// was known at that moment before tearing the rest down.
    private func reportUnexpectedExit(_ name: String, exitStatus: Int32?, wasSignalled: Bool) {
        let output = recorder?.recentText ?? lastOutput
        var fields: [(String, String)] = [("server", name)]
        if let exitStatus { fields.append(("exit", String(exitStatus))) }
        if wasSignalled { fields.append(("terminatedBy", "signal")) }
        fields.append(("log", serverLogURL.path))
        diagnostics.error("proxy", "\(name) stopped unexpectedly while routing was active", fields)
        diagnostics.appendDetail(output)

        lastOutput = output
        stop(reason: "\(name) stopped unexpectedly")
        let detail = exitStatus.map { " (exit code \($0))" } ?? ""
        status = .failed(
            "\(name) stopped unexpectedly\(detail). Stop routing before restarting it. "
                + "What it last printed is in \(serverLogURL.path)."
        )
    }

    /// Whether the proxy still answers on loopback. Used for logging only: a
    /// missed probe is evidence, not a reason to tear a route down.
    private func isAnswering(port: Int) async -> Bool {
        (try? await healthClient.stats(host: host, port: port)) != nil
    }
}
