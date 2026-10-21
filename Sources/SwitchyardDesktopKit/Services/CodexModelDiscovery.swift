import Darwin
import Foundation

/// A picker-visible model that Codex app-server reports for the active account.
package struct CodexSubscriptionModel: Codable, Equatable, Sendable {
    package let id: String
    package let displayName: String?
    package let isDefault: Bool
    /// Whether Codex reports this model as accepting image input. Absent
    /// metadata reads as text-only: Codex drops an attached image client-side
    /// when a route is advertised text-only, so guessing yes loses the image.
    package let supportsImages: Bool

    package init(id: String, displayName: String?, isDefault: Bool, supportsImages: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.isDefault = isDefault
        self.supportsImages = supportsImages
    }
}

/// Dependency boundary for subscription discovery and its UI tests.
package protocol CodexModelDiscovering: Sendable {
    func discover(using setup: CodexSetup) throws -> [CodexSubscriptionModel]

    /// Largest context window per model id, for the window the route advertises.
    ///
    /// Separate from `discover` because app-server's model list carries no
    /// windows at all, and because a catalog this app cannot read is never
    /// worth failing discovery over — the model list is still usable, the route
    /// just keeps Codex's own default.
    func contextWindows(using setup: CodexSetup) -> [String: Int]

    /// `reasoning_effort` levels each model lists, by model id.
    func supportedEfforts(using setup: CodexSetup) -> [String: [String]]
}

package extension CodexModelDiscovering {
    /// A stub discovers no windows unless it says otherwise.
    package func contextWindows(using setup: CodexSetup) -> [String: Int] { [:] }
    package func supportedEfforts(using setup: CodexSetup) -> [String: [String]] { [:] }
}

/// Discovers models through Codex app-server, which uses the user's existing
/// Codex authentication rather than exposing credentials to switchyard-desktop.
package struct CodexModelDiscovery: Sendable {
    package struct CommandOutput: Sendable {
        package let stdout: Data
        package let stderr: Data
        package let exitStatus: Int32
    }

    package typealias Exchange = @Sendable (_ input: Data, _ environment: [String: String]) throws -> CommandOutput

    package enum Failure: LocalizedError, Equatable, Sendable {
        case codexUnavailable
        case unauthenticated
        case appServerUnavailable
        case invalidResponse
        case incompleteResult
        case noModels

        package var errorDescription: String? {
            switch self {
            case .codexUnavailable:
                return "Codex CLI is required to discover your subscription models."
            case .unauthenticated:
                return "Sign in to Codex, then try discovering models again."
            case .appServerUnavailable:
                return "Codex could not discover subscription models. Check Codex and your connection, then try again."
            case .invalidResponse:
                return "Codex returned an unexpected model list. Update Codex and try again."
            case .incompleteResult:
                return "Codex returned more models than switchyard-desktop can safely verify. Update switchyard-desktop and try again."
            case .noModels:
                return "Codex did not report any selectable subscription models."
            }
        }
    }

    private static let modelListRequestID = 2
    package static let executableName = "codex"
    private let exchange: Exchange
    private let windowReader: any CodexModelWindowReading

    package init(
        exchange: @escaping Exchange = Self.runAppServer,
        windowReader: any CodexModelWindowReading = CodexModelWindowReader()
    ) {
        self.exchange = exchange
        self.windowReader = windowReader
    }

    package func contextWindows(using setup: CodexSetup) -> [String: Int] {
        guard let windows = try? windowReader.windows(using: setup) else { return [:] }
        return windows.compactMapValues(\.largest)
    }

    package func supportedEfforts(using setup: CodexSetup) -> [String: [String]] {
        guard let windows = try? windowReader.windows(using: setup) else { return [:] }
        return windows.compactMapValues { $0.supportedEfforts.isEmpty ? nil : $0.supportedEfforts }
    }

    /// Uses the configuration directory as `CODEX_HOME` so app-server resolves
    /// the same authenticated Codex context that the setup reader validated.
    package func discover(using setup: CodexSetup) throws -> [CodexSubscriptionModel] {
        let output: CommandOutput
        do {
            output = try exchange(
                Self.requestPayload(),
                Self.environment(for: setup)
            )
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.appServerUnavailable
        }

        guard output.exitStatus == 0 else {
            throw Self.failure(for: output)
        }

        return try Self.models(from: output.stdout)
    }

    private static func environment(for setup: CodexSetup) -> [String: String] {
        // A `PATH` the Codex CLI's own child processes can use, not the minimal
        // one a Finder or Xcode launch hands this app.
        var environment = LaunchEnvironment.childEnvironment()
        environment["CODEX_HOME"] = setup.configPath.deletingLastPathComponent().path
        return environment
    }

    private static func requestPayload() -> Data {
        let messages: [[String: Any]] = [
            [
                "method": "initialize",
                "id": 1,
                "params": [
                    "clientInfo": [
                        "name": "switchyard-desktop",
                        "title": "switchyard-desktop",
                        "version": "0.1.0",
                    ],
                ],
            ],
            [
                "method": "initialized",
                "params": [:],
            ],
            [
                "method": "model/list",
                "id": modelListRequestID,
                "params": [
                    "limit": 100,
                    "includeHidden": false,
                ],
            ],
        ]

        var payload = Data()
        for message in messages {
            // All values are literals controlled by this process.
            let line = try! JSONSerialization.data(withJSONObject: message)
            payload.append(line)
            payload.append(0x0A)
        }
        return payload
    }

    /// How long to wait for app-server to answer the model list.
    private static let responseTimeout: TimeInterval = 30

    private static func runAppServer(
        input: Data,
        environment: [String: String]
    ) throws -> CommandOutput {
        // Resolved here rather than through `/usr/bin/env`, which only sees the
        // launching process's `PATH`.
        guard let executable = LaunchEnvironment.locate(executableName) else {
            throw Failure.codexUnavailable
        }

        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()

        process.executableURL = executable
        process.arguments = ["app-server"]
        process.environment = environment
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw Failure.appServerUnavailable
        }

        standardInput.fileHandleForWriting.write(input)

        // app-server shuts down as soon as stdin reaches EOF, and it can do so
        // before it has answered model/list. So the request stays open until
        // the response arrives, the stream ends, or the wait times out.
        let stdout = readUntilModelList(
            standardOutput.fileHandleForReading,
            deadline: Date().addingTimeInterval(responseTimeout)
        )

        try? standardInput.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()

        return CommandOutput(
            stdout: stdout.data,
            stderr: standardError.fileHandleForReading.readDataToEndOfFile(),
            // Terminating a server that already answered is not a failure.
            exitStatus: stdout.sawResponse ? 0 : process.terminationStatus
        )
    }

    /// Reads newline-delimited output until the model-list response shows up.
    private static func readUntilModelList(
        _ handle: FileHandle,
        deadline: Date
    ) -> (data: Data, sawResponse: Bool) {
        var data = Data()
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, waitForData(handle.fileDescriptor, seconds: remaining) else {
                return (data, false)
            }
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return (data, containsModelListResponse(data)) }
            data.append(chunk)
            if containsModelListResponse(data) { return (data, true) }
        }
    }

    private static func waitForData(_ descriptor: Int32, seconds: TimeInterval) -> Bool {
        var descriptors = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32((seconds * 1_000).rounded(.up))
        return poll(&descriptors, 1, milliseconds) > 0
    }

    /// True once a complete line carries the response to the model-list request.
    private static func containsModelListResponse(_ data: Data) -> Bool {
        guard let lastBreak = data.lastIndex(of: 0x0A) else { return false }
        return data[..<lastBreak]
            .split(separator: 0x0A)
            .contains { line in
                (try? JSONDecoder().decode(AppServerResponse.self, from: Data(line)))?.id
                    == modelListRequestID
            }
    }

    private static func models(from output: Data) throws -> [CodexSubscriptionModel] {
        for line in output.split(separator: 0x0A) {
            guard let response = try? JSONDecoder().decode(
                AppServerResponse.self,
                from: Data(line)
            ),
            response.id == modelListRequestID else {
                continue
            }

            if let error = response.error {
                throw failure(for: error)
            }
            guard let result = response.result else {
                throw Failure.invalidResponse
            }
            guard result.nextCursor == nil else {
                // Do not silently offer an incomplete subset as the subscription list.
                throw Failure.incompleteResult
            }

            var seen = Set<String>()
            let models = result.data.compactMap { entry -> CodexSubscriptionModel? in
                guard entry.hidden != true,
                      let rawID = entry.model ?? entry.id else {
                    return nil
                }
                let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, seen.insert(id).inserted else {
                    return nil
                }
                return CodexSubscriptionModel(
                    id: id,
                    displayName: entry.displayName,
                    isDefault: entry.isDefault ?? false,
                    supportsImages: entry.inputModalities?.contains("image") ?? false
                )
            }
            guard !models.isEmpty else {
                throw Failure.noModels
            }
            return models
        }

        throw Failure.invalidResponse
    }

    private static func failure(for output: CommandOutput) -> Failure {
        let diagnostics = String(decoding: output.stderr + output.stdout, as: UTF8.self)
        if isAuthenticationFailure(diagnostics) {
            return .unauthenticated
        }
        if output.exitStatus == 127 || diagnostics.localizedCaseInsensitiveContains("command not found") {
            return .codexUnavailable
        }
        return .appServerUnavailable
    }

    private static func failure(for error: AppServerError) -> Failure {
        if error.code == 401 || error.code == 403 || isAuthenticationFailure(error.message) {
            return .unauthenticated
        }
        return .appServerUnavailable
    }

    private static func isAuthenticationFailure(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized.contains("unauthenticated")
            || normalized.contains("unauthorized")
            || normalized.contains("not logged in")
            || normalized.contains("sign in")
            || normalized.contains("login")
    }
}

extension CodexModelDiscovery: CodexModelDiscovering {}

private struct AppServerResponse: Decodable {
    package let id: Int?
    package let result: ModelListResult?
    package let error: AppServerError?
}

private struct ModelListResult: Decodable {
    package let data: [ModelListEntry]
    package let nextCursor: String?
}

private struct ModelListEntry: Decodable {
    package let id: String?
    package let model: String?
    package let displayName: String?
    package let hidden: Bool?
    package let isDefault: Bool?
    package let inputModalities: [String]?
}

private struct AppServerError: Decodable {
    package let code: Int?
    package let message: String
}
