import Foundation

/// Maximum model windows from Codex's account-specific catalog. Reading the
/// cache also works while routing is stopped and never starts another server.
package final class CodexModelContextReader: @unchecked Sendable {
    package let url: URL
    package static let byteLimit = 4 * 1_024 * 1_024
    private let lock = NSLock()
    private var cachedData: Data?
    private var cachedWindows: [String: Int] = [:]

    package init(configPath: URL = CodexLocations.defaultConfigURL) {
        url = configPath.deletingLastPathComponent().appendingPathComponent("models_cache.json")
    }

    package func contextWindows() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return clearCache() }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.byteLimit + 1),
              data.count <= Self.byteLimit else { return clearCache() }
        if data == cachedData { return cachedWindows }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return clearCache() }
        var windows: [String: Int] = [:]
        for model in models {
            guard let id = model["slug"] as? String, !id.isEmpty,
                  // context_window is the client's default; the upstream
                  // model can accept more when max_context_window is supplied.
                  let limit = Self.positiveInteger(model["max_context_window"])
                    ?? Self.positiveInteger(model["context_window"]) else { continue }
            windows[id] = limit
        }
        cachedData = data
        cachedWindows = windows
        return windows
    }

    private static func positiveInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let limit = Int(number.stringValue), limit > 0 else { return nil }
        return limit
    }

    private func clearCache() -> [String: Int] {
        cachedData = nil
        cachedWindows = [:]
        return [:]
    }
}
