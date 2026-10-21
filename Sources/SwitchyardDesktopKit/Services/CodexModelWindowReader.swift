import Foundation

/// What one model in Codex's catalog will accept.
///
/// `contextWindow` is the window Codex uses by default; `maxContextWindow` is
/// the largest the model accepts. They differ — the whole GPT-5.6 family
/// defaults to 272k while accepting 872k — so a router that wants the full
/// capacity has to name the maximum itself.
package struct CodexModelWindow: Codable, Equatable, Sendable {
    package let contextWindow: Int?
    package let maxContextWindow: Int?
    /// `reasoning_effort` values this model lists, lowest first. Switchyard
    /// forwards whatever a role names, so this is the only place that can say
    /// a level will not be understood.
    package var supportedEfforts: [String] = []

    /// The largest window this model is documented to take.
    package var largest: Int? {
        guard let candidates = [maxContextWindow, contextWindow].compactMap({ $0 }).max(),
              candidates > 0 else { return nil }
        return candidates
    }
}

/// Dependency boundary for window discovery and its tests.
package protocol CodexModelWindowReading: Sendable {
    func windows(using setup: CodexSetup?) throws -> [String: CodexModelWindow]
}

/// Reads per-model context windows from `codex debug models`.
///
/// `model/list` on app-server — the source of the model picker — carries no
/// windows, and `models_cache.json` is empty for as long as routing is on,
/// because Codex then fetches its catalog from the router and the router
/// advertises one route. `codex debug models` renders the catalog Codex would
/// actually apply, whichever of those it came from, so it answers while routing
/// is running as well as while it is stopped.
package struct CodexModelWindowReader: Sendable {
    package struct CommandOutput: Sendable {
        package let stdout: Data
        package let exitStatus: Int32
    }

    package typealias Run = @Sendable (_ environment: [String: String]) throws -> CommandOutput

    package enum Failure: LocalizedError, Equatable, Sendable {
        case codexUnavailable
        case commandFailed
        case invalidResponse

        package var errorDescription: String? {
            switch self {
            case .codexUnavailable:
                return "Codex CLI is required to read model context windows."
            case .commandFailed:
                return "Codex could not render its model catalog."
            case .invalidResponse:
                return "Codex returned a model catalog switchyard-desktop could not read."
            }
        }
    }

    package static let executableName = "codex"
    /// The catalog carries every model's base instructions, so it is large.
    package static let byteLimit = 16 * 1_024 * 1_024
    private static let timeout: TimeInterval = 30

    private let run: Run

    package init(run: @escaping Run = Self.runDebugModels) {
        self.run = run
    }

    /// - Parameter setup: the validated Codex installation, used as `CODEX_HOME`
    ///   so the catalog belongs to the same account the rest of the app reads.
    package func windows(using setup: CodexSetup? = nil) throws -> [String: CodexModelWindow] {
        let output: CommandOutput
        do {
            output = try run(Self.environment(for: setup))
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.commandFailed
        }
        guard output.exitStatus == 0 else { throw Failure.commandFailed }
        return try Self.windows(from: output.stdout)
    }

    package static func windows(from data: Data) throws -> [String: CodexModelWindow] {
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
            throw Failure.invalidResponse
        }
        var windows: [String: CodexModelWindow] = [:]
        for model in catalog.models {
            let id = model.slug.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            let window = CodexModelWindow(
                contextWindow: positive(model.contextWindow),
                maxContextWindow: positive(model.maxContextWindow),
                supportedEfforts: (model.supportedReasoningLevels ?? []).map(\.effort)
            )
            guard window.largest != nil || !window.supportedEfforts.isEmpty else { continue }
            windows[id] = window
        }
        guard !windows.isEmpty else { throw Failure.invalidResponse }
        return windows
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func environment(for setup: CodexSetup?) -> [String: String] {
        var environment = LaunchEnvironment.childEnvironment()
        if let setup {
            environment["CODEX_HOME"] = setup.configPath.deletingLastPathComponent().path
        }
        return environment
    }

    private static func runDebugModels(environment: [String: String]) throws -> CommandOutput {
        guard let executable = LaunchEnvironment.locate(executableName) else {
            throw Failure.codexUnavailable
        }

        let process = Process()
        let standardOutput = Pipe()
        process.executableURL = executable
        process.arguments = ["debug", "models"]
        process.environment = environment
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw Failure.commandFailed
        }

        // Read before waiting: the catalog is far larger than a pipe buffer, so
        // waiting first would deadlock on a full pipe.
        let handle = standardOutput.fileHandleForReading
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        while data.count <= byteLimit {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if Date() >= deadline { break }
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()

        return CommandOutput(
            stdout: data,
            // A catalog already read in full is not a failure, however the
            // process ended.
            exitStatus: data.isEmpty ? process.terminationStatus : 0
        )
    }
}

extension CodexModelWindowReader: CodexModelWindowReading {}

package extension CodexModelWindowReader {
    fileprivate struct Catalog: Decodable {
        package let models: [Entry]
    }

    fileprivate struct Entry: Decodable {
        package let slug: String
        package let contextWindow: Int?
        package let maxContextWindow: Int?
        package let supportedReasoningLevels: [Level]?

        package struct Level: Decodable {
            package let effort: String
        }

        private enum CodingKeys: String, CodingKey {
            case slug
            case contextWindow = "context_window"
            case maxContextWindow = "max_context_window"
            case supportedReasoningLevels = "supported_reasoning_levels"
        }
    }
}
