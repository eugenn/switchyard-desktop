import Foundation
import TOMLKit

/// Undoes the one thing an older version of this app did that this one never
/// does: edit `~/.codex/config.toml` in place.
///
/// Reached only by upgrading while such a route was active. Today's app adds its
/// own `switchyard-desktop.config.toml` instead, so this runs once, at the first
/// launch after the upgrade, and then the record is gone for good.
package enum LegacyCodexConfigRestore {
    package enum Outcome: Equatable {
        /// The patched configuration was put back, or removed when this app had
        /// created it.
        case restored(String)
        /// The record named a configuration this app no longer owns — another
        /// client has taken it over since, or it was already restored.
        case nothingToRestore
        case failed(String)
    }

    package static func run(_ session: LegacyPatchedConfigSession) -> Outcome {
        let capture = session.codexCapture
        guard selectsLegacyProvider(configPath: capture.configPath) else {
            return .nothingToRestore
        }

        do {
            if capture.originalConfigExisted {
                guard let backupPath = capture.backupPath,
                      FileManager.default.fileExists(atPath: backupPath.path) else {
                    return .failed(
                        """
                        switchyard-desktop used to edit \(capture.configPath.path) and this version \
                        does not, but the backup it recorded is gone. Restore the file from a \
                        `config.toml.bak-` copy beside it, then choose your model in Codex again.
                        """
                    )
                }
                try Data(contentsOf: backupPath).write(to: capture.configPath, options: .atomic)
                try? FileManager.default.removeItem(at: backupPath)
            } else {
                try FileManager.default.removeItem(at: capture.configPath)
            }
        } catch {
            return .failed(
                """
                switchyard-desktop used to edit \(capture.configPath.path) and could not put it back: \
                \(error.localizedDescription)
                Restore it from a `config.toml.bak-` copy beside it.
                """
            )
        }

        return .restored(
            """
            An earlier version of switchyard-desktop edited \(capture.configPath.path) directly, and \
            that change has now been undone. This version never touches that file: it adds \
            \(CodexLocations.defaultProfileURL.lastPathComponent) beside it and routes only the \
            sessions you start with `\(CodexLocations.launchCommand)`.
            """
        )
    }

    /// The provider name the old writer installed. Deliberately spelled out
    /// rather than shared with today's writer: this checks a legacy artefact,
    /// and it must keep matching it if the current name ever changes.
    private static let legacyProviderKey = "switchyard-desktop"

    private static func selectsLegacyProvider(configPath: URL) -> Bool {
        guard let text = try? String(contentsOf: configPath, encoding: .utf8),
              let table = try? TOMLTable(string: text) else {
            return false
        }
        return table["model_provider"]?.string == legacyProviderKey
    }
}
