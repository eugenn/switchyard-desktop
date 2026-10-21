import Foundation

/// The two Codex files this app knows about, and the only place their paths are
/// formed.
///
/// Their ownership is deliberately different. `config.toml` is the user's: it is
/// read for discovery and never written. `switchyard-desktop.config.toml` is this
/// app's own layer — Codex loads `$CODEX_HOME/<name>.config.toml` on top of the
/// user's configuration when a session starts as `codex --profile <name>`, so
/// routing is installed by adding a file instead of editing one.
package enum CodexLocations {
    /// The `--profile` name a routed Codex session is started with.
    package static let profileName = "switchyard-desktop"

    /// What the user types to start a routed session.
    package static var launchCommand: String { "codex --profile \(profileName)" }

    /// `$CODEX_HOME`, defaulting to `~/.codex` for the current user.
    package static var defaultHome: URL {
        home(codexHome: ProcessInfo.processInfo.environment["CODEX_HOME"], userHome: UserDataLocations.home)
    }

    package static func home(codexHome: String?, userHome: URL) -> URL {
        codexHome.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        } ?? userHome.appendingPathComponent(".codex", isDirectory: true)
    }

    /// The user's own Codex configuration. Read-only for this app.
    package static var defaultConfigURL: URL { defaultHome.appendingPathComponent("config.toml") }

    package static func configURL(codexHome: String?, userHome: URL) -> URL {
        home(codexHome: codexHome, userHome: userHome).appendingPathComponent("config.toml")
    }

    /// The layer this app generates, beside the user's configuration.
    package static var defaultProfileURL: URL {
        defaultHome.appendingPathComponent("\(profileName).config.toml")
    }

    package static func profileURL(codexHome: String?, userHome: URL) -> URL {
        home(codexHome: codexHome, userHome: userHome)
            .appendingPathComponent("\(profileName).config.toml")
    }
}
