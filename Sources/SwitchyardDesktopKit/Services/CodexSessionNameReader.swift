import Foundation

/// The names Codex gives its own conversations, read from the index it keeps
/// beside its config: `$CODEX_HOME/session_index.jsonl`.
///
/// Switchyard's `session_id` is Codex's own conversation id, so the two line up
/// and a routed turn can be shown under the thread name the user already sees
/// in Codex. The file belongs to Codex: it is only ever read, never written,
/// and a missing, unreadable or differently shaped index simply leaves every
/// session named by its id.
///
/// Codex appends a fresh line whenever a thread is renamed or used again, so
/// the last line for an id wins.
package final class CodexSessionNameReader: @unchecked Sendable {
    package static var defaultURL: URL {
        indexURL(configPath: CodexLocations.defaultConfigURL)
    }

    package static func indexURL(configPath: URL) -> URL {
        configPath.deletingLastPathComponent()
            .appendingPathComponent("session_index.jsonl")
    }

    /// The index is a small file Codex prunes itself; this is a hard cap so an
    /// unexpectedly large one cannot stall a refresh.
    package static let byteLimit = 4 * 1_024 * 1_024

    package let url: URL
    private let lock = NSLock()
    private var cachedData: Data?
    private var cachedNames: [String: String] = [:]

    package init(url: URL = CodexSessionNameReader.defaultURL) {
        self.url = url
    }

    /// Conversation id to the name Codex shows for it. Empty when the index is
    /// absent or carries no usable line.
    package func names() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = tailData() else {
            cachedData = nil
            cachedNames = [:]
            return [:]
        }
        if data == cachedData { return cachedNames }

        var names: [String: String] = [:]
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let entry = object as? [String: Any],
                  let id = entry["id"] as? String, !id.isEmpty,
                  let name = (entry["thread_name"] ?? entry["name"]) as? String else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            // A later line for the same id is the current name, including a
            // rename back to nothing.
            names[id] = trimmed.isEmpty ? nil : trimmed
        }
        cachedData = data
        cachedNames = names
        return names
    }

    /// The tail only, with a partial first line dropped, so the cap holds for a
    /// file Codex has grown past it.
    private func tailData() -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(Self.byteLimit) ? size - UInt64(Self.byteLimit) : 0
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: Int(size - offset)) ?? Data()
            guard offset > 0 else { return data }
            guard let firstBreak = data.firstIndex(of: UInt8(ascii: "\n")) else { return Data() }
            return data[(firstBreak + 1)...]
        } catch {
            return nil
        }
    }
}
