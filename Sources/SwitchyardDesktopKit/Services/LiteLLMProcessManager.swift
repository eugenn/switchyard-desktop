import Darwin
import Foundation
import Observation

/// Starts the packaged Python/LiteLLM runtime; never installs software at runtime.
@MainActor
@Observable
package final class LiteLLMProcessManager {
    package nonisolated static let port = 4101
    package nonisolated static let upstream = "http://127.0.0.1:4101/v1"
    /// The independent NVIDIA checkout experiment; never started or stopped by this app.
    package nonisolated static let developmentUpstream = "http://127.0.0.1:4001/v1"
    package private(set) var loginMessage = ""
    private var loginOutput = ChatGPTSignInOutput()
    private var process: Process?
    private var loginProcess: Process?
    private var loginID: UUID?
    private var recorder: ChildOutputRecorder?
    private let diagnostics: DiagnosticLog
    private let registry: any ManagedProcessRecording
    package var isRunning: Bool { process?.isRunning == true }

    /// PID of the managed runtime, if one is running.
    package var runningPID: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }

    package init(
        diagnostics: DiagnosticLog = .shared,
        registry: any ManagedProcessRecording = ManagedProcessRegistry.standard()
    ) {
        self.diagnostics = diagnostics
        self.registry = registry
    }

    /// Where this manager keeps the runtime's own stdout and stderr.
    package var serverLogURL: URL { diagnostics.companionURL(named: "litellm.log") }

    package nonisolated static var runtimeURL: URL? {
        AppRuntimeLocator.liteLLMURL()
    }

    package nonisolated static var isAvailable: Bool {
        AppRuntimeLocator.isLiteLLMAvailable(at: runtimeURL)
    }

    package struct Failure: LocalizedError {
        package let message: String
        package var errorDescription: String? { message }
    }

    package nonisolated static func configuration(models: [LiteLLMModel]) throws -> Data {
        // JSON is a YAML subset, and safely quotes arbitrary model identifiers.
        let config: [String: Any] = [
            "model_list": Array(Set(models)).sorted { $0.name < $1.name }.map {
                ["model_name": $0.name, "litellm_params": ["model": "chatgpt/\($0.upstreamModel)"]] as [String: Any]
            },
            "litellm_settings": ["telemetry": false, "set_verbose": false],
            "general_settings": ["disable_spend_logs": true],
        ]
        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    }

    private func child(runtime: URL, arguments: [String]) -> Process {
        let child = Process()
        child.executableURL = runtime.appendingPathComponent("bin/python3.12")
        child.arguments = ["-I", "-u", runtime.appendingPathComponent("launcher.py").path] + arguments
        child.currentDirectoryURL = SwitchyardConfigWriter.supportDirectory
        // Python runs in isolated mode. Preserve LiteLLM's existing OAuth location.
        child.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin",
            "LITELLM_LOCAL_MODEL_COST_MAP": "True",
            "LITELLM_TELEMETRY": "False",
        ]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        return child
    }

    package func start(models: [LiteLLMModel]) async throws {
        if let existing = process {
            guard !existing.isRunning else { return }
            // The runtime from the previous start died. Without clearing it,
            // this call would report success and the proxy would be pointed at
            // a port nothing answers on.
            diagnostics.warning("litellm", "Clearing a LiteLLM runtime that is no longer running", [
                ("pid", String(existing.processIdentifier))
            ])
            stop()
        }
        guard let runtime = Self.runtimeURL, Self.isAvailable else {
            let message = AppRuntimeLocator.missingLiteLLMMessage
            diagnostics.error("litellm", message)
            throw Failure(message: message)
        }
        guard RoutingReadinessChecker.isPortAvailable(host: "127.0.0.1", port: Self.port) else {
            let message = "LiteLLM port \(Self.port) is in use. Stop the conflicting process before starting routing."
            diagnostics.error("litellm", message, [("port", String(Self.port))])
            throw Failure(message: message)
        }
        diagnostics.info("litellm", "Starting the bundled LiteLLM runtime", [
            ("port", String(Self.port)),
            ("models", String(Set(models).count)),
            ("log", serverLogURL.path),
        ])
        let directory = SwitchyardConfigWriter.supportDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = directory.appendingPathComponent("litellm.yaml")
        try Self.configuration(models: models).write(to: config, options: .atomic)
        do {
            // Login output contains the user-facing device challenge only. The
            // proxy's own output is recorded, redacted, in `serverLogURL`.
            let login = child(runtime: runtime, arguments: ["--login"])
            let pipe = Pipe()
            login.standardOutput = pipe
            loginProcess = login
            let loginID = UUID()
            self.loginID = loginID
            loginOutput = ChatGPTSignInOutput()
            loginMessage = "Checking LiteLLM's ChatGPT session…"
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    // EOF remains readable; leaving the handler installed can
                    // spin until the rest of startup finishes.
                    handle.readabilityHandler = nil
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self, self.loginID == loginID else { return }
                    self.loginOutput.append(data)
                    self.loginMessage = self.loginOutput.message
                }
            }
            defer { pipe.fileHandleForReading.readabilityHandler = nil }
            try login.run()
            let deadline = Date().addingTimeInterval(16 * 60)
            while login.isRunning && Date() < deadline {
                try await Task.sleep(for: .milliseconds(200))
            }
            guard !login.isRunning, login.terminationStatus == 0 else {
                diagnostics.error("litellm", "ChatGPT sign-in did not complete", [
                    ("exit", login.isRunning ? "timed-out" : String(login.terminationStatus))
                ])
                throw Failure(message: "ChatGPT sign-in did not complete. Start routing again to retry.")
            }
            loginProcess = nil
            self.loginID = nil
            loginOutput = ChatGPTSignInOutput()
            loginMessage = ""
            let server = child(runtime: runtime, arguments: ["--config", config.path, "--host", "127.0.0.1", "--port", String(Self.port)])
            // Kept, not discarded: when the runtime dies mid-session its last
            // output is the only account of why routing stopped. Draining it
            // also keeps a full pipe from blocking the runtime itself.
            let recorder = ChildOutputRecorder(url: serverLogURL)
            recorder.begin(banner: "litellm starting on 127.0.0.1:\(Self.port)")
            server.standardOutput = recorder.pipe
            server.standardError = recorder.pipe
            try server.run()
            recorder.closeWriteEnd()
            self.recorder = recorder
            process = server
            // Written down before the readiness wait below: this runtime holds
            // port 4101 from the moment it starts, and a crash during startup
            // would otherwise leave it there unattributed.
            registry.record(
                ManagedProcessRecord(
                    name: "LiteLLM",
                    pid: server.processIdentifier,
                    port: Self.port,
                    executablePath: runtime.appendingPathComponent("bin/python3.12")
                        .standardizedFileURL.path,
                    startedAt: Date()
                )
            )
            diagnostics.info("litellm", "LiteLLM is starting", [("pid", String(server.processIdentifier))])
            let health = URL(string: "http://127.0.0.1:\(Self.port)/health/liveliness")!
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            for _ in 0..<120 {
                guard server.isRunning else {
                    diagnostics.error("litellm", "LiteLLM stopped during startup", [
                        ("exit", String(server.terminationStatus)),
                        ("log", serverLogURL.path),
                    ])
                    diagnostics.appendDetail(recorder.recentText)
                    throw Failure(message: "LiteLLM stopped during startup. Check the bundled runtime and configuration.")
                }
                var request = URLRequest(url: health)
                request.timeoutInterval = 0.5
                if let (_, response) = try? await session.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200 {
                    diagnostics.info("litellm", "LiteLLM is ready", [
                        ("pid", String(server.processIdentifier)),
                        ("port", String(Self.port)),
                    ])
                    return
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            diagnostics.error("litellm", "LiteLLM did not become ready in time", [
                ("port", String(Self.port)),
                ("log", serverLogURL.path),
            ])
            diagnostics.appendDetail(recorder.recentText)
            throw Failure(message: "LiteLLM did not become ready in time.")
        } catch {
            stop()
            throw error
        }
    }

    package func stop() {
        let stoppedPID = process?.isRunning == true ? process?.processIdentifier : nil
        // Forgotten even when it already exited on its own: a record kept for a
        // dead PID is what makes a later launch stop an unrelated process.
        let recordedPID = process?.processIdentifier
        loginID = nil
        for child in [loginProcess, process].compactMap({ $0 }) where child.isRunning {
            child.terminate()
            let deadline = Date().addingTimeInterval(2)
            while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
        }
        loginProcess = nil
        process = nil
        if let recordedPID { registry.forget(pid: recordedPID) }
        loginMessage = ""
        loginOutput = ChatGPTSignInOutput()
        if let recorder {
            recorder.finish(banner: "litellm stopped")
            self.recorder = nil
        }
        if let stoppedPID {
            diagnostics.info("litellm", "LiteLLM stopped", [("pid", String(stoppedPID))])
        }
    }
}
