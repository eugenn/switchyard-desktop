import Foundation

/// App-wide choices the user makes in Settings, kept apart from any one
/// routing setup so loading a preset or a saved setup cannot undo them.
package struct AppPreferences: Codable, Equatable, Sendable {
    /// Whether a routed conversation may grow past OpenAI's 272k-token
    /// threshold, above which a prompt costs twice the input rate and one and a
    /// half times the output rate. Allowed until the user says otherwise, which
    /// is what the route did before the setting existed.
    package var allowsLongContext: Bool

    package init(allowsLongContext: Bool = true) {
        self.allowsLongContext = allowsLongContext
    }

    private enum CodingKeys: String, CodingKey {
        case allowsLongContext
    }

    /// A field a later build adds must not make an older file unreadable, nor
    /// the reverse: whatever is missing keeps its default.
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowsLongContext = try container.decodeIfPresent(Bool.self, forKey: .allowsLongContext) ?? true
    }
}

package protocol AppPreferencesStoring: AnyObject, Sendable {
    func load() throws -> AppPreferences?
    func save(_ preferences: AppPreferences) throws
}

/// The preferences on disk, beside the saved setup.
package final class AppPreferencesStore: AppPreferencesStoring, @unchecked Sendable {
    package static var defaultURL: URL {
        UserDataLocations.supportDirectory.appendingPathComponent("preferences.json")
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    package init(fileURL: URL = AppPreferencesStore.defaultURL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    package func load() throws -> AppPreferences? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try decoder.decode(AppPreferences.self, from: Data(contentsOf: fileURL))
    }

    package func save(_ preferences: AppPreferences) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(preferences).write(to: fileURL, options: .atomic)
    }
}
