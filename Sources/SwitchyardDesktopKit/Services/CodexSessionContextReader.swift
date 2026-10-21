import Foundation

/// The context window Codex applies to one conversation, read from the rollout
/// it keeps under `$CODEX_HOME/sessions/<yyyy>/<mm>/<dd>/`.
///
/// While routing is on, Codex asks the router for its model catalog, and the
/// router advertises one route with no window, so `models_cache.json` names no
/// model and the per-model maximums are unavailable. The rollout still records
/// `model_context_window` on every turn: the limit Codex measures the
/// conversation against and compacts it at. The files belong to Codex and are
/// only ever read.
package final class CodexSessionContextReader: @unchecked Sendable {
    /// The window is repeated on every token count, so the tail is enough.
    package static let tailByteLimit = 1_024 * 1_024
    /// Rollouts are filed by day. A conversation older than this is not one the
    /// statistics window is still showing.
    package static let dayLimit = 60

    package let directory: URL
    /// A conversation routed by something other than the Codex CLI never gains
    /// a rollout, so a miss is remembered — but only for a while, since Codex
    /// may still be creating the file for a conversation just started.
    package let missRetryInterval: TimeInterval
    private let lock = NSLock()
    private var located: [String: URL] = [:]
    private var missing: [String: Date] = [:]
    private var cached: [String: (size: UInt64, window: Int?)] = [:]

    package static func sessionsURL(configPath: URL) -> URL {
        configPath.deletingLastPathComponent().appendingPathComponent("sessions")
    }

    package init(configPath: URL = CodexLocations.defaultConfigURL, missRetryInterval: TimeInterval = 30) {
        directory = Self.sessionsURL(configPath: configPath)
        self.missRetryInterval = missRetryInterval
    }

    package init(directory: URL, missRetryInterval: TimeInterval = 30) {
        self.directory = directory
        self.missRetryInterval = missRetryInterval
    }

    /// Codex's own window for that conversation, or nil when its rollout is
    /// absent, unreadable or carries no window yet.
    package func contextWindow(sessionID: String) -> Int? {
        guard !sessionID.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }

        guard let url = resolve(sessionID), let size = fileSize(of: url) else { return nil }
        if let entry = cached[sessionID], entry.size == size { return entry.window }
        let window = Self.lastWindow(in: tailData(of: url))
        cached[sessionID] = (size, window)
        return window
    }

    /// Whether Codex keeps a rollout for that conversation. A thread it opens
    /// for its own housekeeping, such as naming a new conversation, never gets one.
    package func hasRollout(sessionID: String) -> Bool {
        guard !sessionID.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return resolve(sessionID) != nil
    }

    // MARK: - Locating

    /// The rollout file name ends with the conversation id Switchyard logs.
    private func resolve(_ sessionID: String) -> URL? {
        if let known = located[sessionID] {
            guard FileManager.default.fileExists(atPath: known.path) else {
                located[sessionID] = nil
                cached[sessionID] = nil
                return nil
            }
            return known
        }
        if let seen = missing[sessionID], Date().timeIntervalSince(seen) < missRetryInterval { return nil }

        let suffix = "-\(sessionID).jsonl"
        for day in dayDirectories() {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: day, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            if let match = files.first(where: { $0.lastPathComponent.hasSuffix(suffix) }) {
                located[sessionID] = match
                missing[sessionID] = nil
                return match
            }
        }
        missing[sessionID] = Date()
        return nil
    }

    /// Day directories, newest first, so an active conversation is found in the
    /// first listing instead of a walk of every rollout Codex has ever kept.
    private func dayDirectories() -> [URL] {
        var days: [URL] = []
        for year in descendingSubdirectories(of: directory) {
            for month in descendingSubdirectories(of: year) {
                for day in descendingSubdirectories(of: month) {
                    days.append(day)
                    if days.count >= Self.dayLimit { return days }
                }
            }
        }
        return days
    }

    private func descendingSubdirectories(of url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: - Reading

    private func fileSize(of url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.uint64Value
    }

    private func tailData(of url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return Data() }
        let offset = size > UInt64(Self.tailByteLimit) ? size - UInt64(Self.tailByteLimit) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: Int(size - offset)) else { return Data() }
        return data
    }

    /// The last window the tail declares. A rollout line carries whole tool
    /// outputs, so the key is found by scanning backwards rather than by
    /// decoding megabytes of JSON on every refresh.
    package static func lastWindow(in data: Data) -> Int? {
        let key = Array(#""model_context_window":"#.utf8)
        let bytes = Array(data)
        guard bytes.count >= key.count else { return nil }
        var start = bytes.count - key.count
        while start >= 0 {
            defer { start -= 1 }
            guard bytes[start] == key[0] else { continue }
            var matched = 1
            while matched < key.count, bytes[start + matched] == key[matched] { matched += 1 }
            guard matched == key.count else { continue }

            var index = start + key.count
            while index < bytes.count, bytes[index] == UInt8(ascii: " ") { index += 1 }
            var value = 0
            var digits = 0
            while index < bytes.count, bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "9") {
                value = value * 10 + Int(bytes[index] - UInt8(ascii: "0"))
                digits += 1
                guard digits <= 12 else { return nil }
                index += 1
            }
            // `null` before the first turn is not a window; keep looking back.
            guard digits > 0, value > 0 else { continue }
            return value
        }
        return nil
    }
}
