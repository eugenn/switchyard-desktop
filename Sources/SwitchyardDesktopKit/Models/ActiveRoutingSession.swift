import Foundation

/// Persistent evidence that this app generated a Codex profile layer and left a
/// proxy running for it.
///
/// It exists for tidiness, not for safety. The layer it names is this app's own
/// file: a run that never gets to delete it leaves the user's Codex
/// configuration untouched, and only a session started with
/// `codex --profile switchyard-desktop` would notice. The next launch removes it.
package struct ActiveRoutingSession: Codable, Equatable, Sendable {
    package let routingConfigPath: URL
    package let codexProfilePath: URL
    package let startedAt: Date

    /// Whether the generated layer is still on disk and has to be cleaned up.
    ///
    /// A file that no longer selects this app's provider is not this app's to
    /// delete, so it does not count as something to clean up either.
    package func requiresCleanUp() -> Bool {
        CodexProfileWriter.isInstalled(profilePath: codexProfilePath)
    }
}

/// A record left by a version of this app that patched `~/.codex/config.toml`
/// in place, kept only so an upgrade mid-route can put that file back.
///
/// Nothing writes this shape any more. It is read once at launch and removed.
package struct LegacyPatchedConfigSession: Codable, Equatable, Sendable {
    package struct Capture: Codable, Equatable, Sendable {
        package let configPath: URL
        package let backupPath: URL?
        package let originalConfigExisted: Bool
    }

    package let codexCapture: Capture
    package let startedAt: Date
}

/// File persistence is deliberately small and local: no credentials, request
/// content, proxy output, or profile values are recorded.
package protocol ActiveRoutingSessionStoring: AnyObject {
    func load() throws -> ActiveRoutingSession?
    func save(_ session: ActiveRoutingSession) throws
    func clear() throws
    /// A record from a version that edited the user's own configuration, if the
    /// stored record is one. Only the real store has any.
    func loadLegacyPatchedConfig() -> LegacyPatchedConfigSession?
}

package extension ActiveRoutingSessionStoring {
    package func loadLegacyPatchedConfig() -> LegacyPatchedConfigSession? { nil }
}

package final class ActiveRoutingSessionStore: ActiveRoutingSessionStoring {
    package static var defaultURL: URL {
        UserDataLocations.supportDirectory.appendingPathComponent("active-routing.json")
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    package init(
        fileURL: URL = ActiveRoutingSessionStore.defaultURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    package func load() throws -> ActiveRoutingSession? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try decoder.decode(ActiveRoutingSession.self, from: Data(contentsOf: fileURL))
    }

    /// Tried only after `load()` fails, so a current record never takes this
    /// path. A file that is neither shape is not a legacy record either.
    package func loadLegacyPatchedConfig() -> LegacyPatchedConfigSession? {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(LegacyPatchedConfigSession.self, from: data)
    }

    package func save(_ session: ActiveRoutingSession) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(session)
        try data.write(to: fileURL, options: .atomic)
    }

    package func clear() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}
