import Foundation
import TOMLKit

/// Non-sensitive Codex settings needed to begin subscription model discovery.
///
/// Authentication is intentionally not represented here. The next discovery
/// step uses Codex's own authenticated context rather than exposing credentials.
package struct CodexSetup: Equatable, Sendable {
    package let configPath: URL
    package let model: String?
    package let modelProvider: String?

    package init(configPath: URL, model: String?, modelProvider: String?) {
        self.configPath = configPath
        self.model = model
        self.modelProvider = modelProvider
    }
}

/// Dependency boundary for first-run setup and its UI tests.
package protocol CodexSetupReading: Sendable {
    func read(configPath: URL) throws -> CodexSetup
}

/// Safely reads the existing local Codex configuration before first-run setup.
package struct CodexSetupReader: Sendable {
    package init() {}

    /// Discovery and routing must use the same user's Codex configuration.
    package static var defaultConfigURL: URL { CodexLocations.defaultConfigURL }

    package enum Failure: LocalizedError, Equatable, Sendable {
        case missingConfiguration
        case unreadableConfiguration
        case malformedConfiguration
        case invalidFieldType(String)
        case emptyField(String)

        package var errorDescription: String? {
            switch self {
            case .missingConfiguration:
                return "Codex must be configured before switchyard-desktop can continue."
            case .unreadableConfiguration:
                return "switchyard-desktop could not read the Codex configuration. Check its permissions and try again."
            case .malformedConfiguration:
                return "The Codex configuration is malformed. Fix it in Codex, then try again."
            case .invalidFieldType(let field):
                return "The Codex configuration has an invalid \(field) setting."
            case .emptyField(let field):
                return "The Codex configuration has an empty \(field) setting."
            }
        }
    }

    package func read(configPath: URL = Self.defaultConfigURL) throws -> CodexSetup {
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            // Codex can use defaults without a config file. Authentication and
            // model availability are still checked by app-server discovery.
            // Only Start is allowed to create the routing configuration.
            return CodexSetup(configPath: configPath, model: nil, modelProvider: nil)
        }

        let text: String
        do {
            text = try String(contentsOf: configPath, encoding: .utf8)
        } catch {
            // Deliberately discard the underlying error: it may expose source text.
            throw Failure.unreadableConfiguration
        }

        let table: TOMLTable
        do {
            table = try TOMLTable(string: text)
        } catch {
            // TOML parser diagnostics can include a source line from the config.
            throw Failure.malformedConfiguration
        }

        return CodexSetup(
            configPath: configPath,
            model: try validatedString(named: "model", in: table),
            modelProvider: try validatedString(named: "model_provider", in: table)
        )
    }

    private func validatedString(named field: String, in table: TOMLTable) throws -> String? {
        guard let value = table[field] else { return nil }
        guard let string = value.string else {
            throw Failure.invalidFieldType(field)
        }
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.emptyField(field)
        }
        return string
    }
}

extension CodexSetupReader: CodexSetupReading {}
