import Foundation

/// File mechanics shared by every diagnostic file this app keeps: append,
/// rotate before the file can grow without bound, and read the tail back.
///
/// All of it is plain `FileHandle` work with no shared state, so a caller on
/// any thread may use it as long as it serialises its own writes to one file.
package enum DiagnosticFile {
    /// Keeps exactly one previous generation: enough to survive a rotation
    /// that happens between the incident and the user noticing it.
    package static func previousURL(for url: URL) -> URL {
        let name = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        return url.deletingLastPathComponent().appendingPathComponent("\(name).previous\(suffix)")
    }

    package static func append(_ text: String, to url: URL, byteLimit: Int) {
        guard !text.isEmpty else { return }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        rotateIfNeeded(url, byteLimit: byteLimit)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    package static func rotateIfNeeded(_ url: URL, byteLimit: Int) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? Int, size >= byteLimit else { return }
        let previous = previousURL(for: url)
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
    }

    /// The last `byteLimit` bytes, without the partial line a byte offset cuts
    /// through. An unreadable or absent file reads as empty.
    package static func tail(of url: URL, byteLimit: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(byteLimit) ? size - UInt64(byteLimit) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return "" }
        var text = String(decoding: data, as: UTF8.self)
        if offset > 0, let firstBreak = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstBreak)...])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Append-only record of what this app and the servers it owns did, kept on
/// disk so an unexplained stop can still be explained afterwards — after the
/// app was relaunched, after a crash, or once the user notices that Codex has
/// lost its route. Nothing here is shown as it happens; it exists to be read
/// later.
///
/// Every value passes through `DiagnosticRedactor` first: this file outlives
/// the session that wrote it and must never hold a credential or request
/// content.
package final class DiagnosticLog: @unchecked Sendable {
    package enum Level: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    /// Written in the directory this app owns, beside the routing log — never
    /// in the Codex or Switchyard directories.
    package static var defaultURL: URL {
        SwitchyardConfigWriter.supportDirectory.appendingPathComponent("diagnostics.log")
    }

    /// A test run must never append to the file a real incident is read back
    /// from. `defaultURL` already leads into the per-process sandbox there,
    /// because the directory it sits in is resolved through
    /// `UserDataLocations`.
    package static var isUnderTest: Bool { UserDataLocations.isUnderTest }

    package static let shared = DiagnosticLog(url: defaultURL)

    /// Small enough that the whole file stays readable, large enough to hold
    /// weeks of lifecycle events at the rate this app writes them.
    package static let byteLimit = 512 * 1_024

    package let url: URL
    /// Serialises writes from the main actor, the process monitor, and the
    /// background queue that drains child output.
    private let lock = NSLock()

    package init(url: URL = DiagnosticLog.defaultURL) {
        self.url = url
    }

    /// A sibling file in the same directory, for a child process's own output.
    package func companionURL(named name: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(name)
    }

    package func info(_ category: String, _ message: String, _ fields: [(String, String)] = []) {
        record(.info, category, message, fields)
    }

    package func warning(_ category: String, _ message: String, _ fields: [(String, String)] = []) {
        record(.warning, category, message, fields)
    }

    package func error(_ category: String, _ message: String, _ fields: [(String, String)] = []) {
        record(.error, category, message, fields)
    }

    /// One line per event, `key=value` details last, so the file greps as
    /// easily as it reads.
    package func record(
        _ level: Level,
        _ category: String,
        _ message: String,
        _ fields: [(String, String)] = []
    ) {
        var line = "\(Self.timestamp()) \(level.rawValue) [\(category)] \(Self.clean(message))"
        if !fields.isEmpty {
            let details = fields.map { "\($0.0)=\(Self.clean($0.1))" }.joined(separator: " ")
            line += " | \(details)"
        }
        append(line + "\n")
    }

    /// Multi-line context — a stopped server's last output — kept beneath its
    /// own event and indented so it cannot be mistaken for further events.
    package func appendDetail(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let indented = trimmed
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "    \(DiagnosticRedactor.redact(String($0)))" }
            .joined(separator: "\n")
        append(indented + "\n")
    }

    package func recentText(byteLimit: Int = 64 * 1_024) -> String {
        lock.lock()
        defer { lock.unlock() }
        return DiagnosticFile.tail(of: url, byteLimit: byteLimit)
    }

    private func append(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        DiagnosticFile.append(text, to: url, byteLimit: Self.byteLimit)
    }

    /// A newline in a value would forge an event, and every recorded value is
    /// short enough that collapsing it loses nothing.
    private static func clean(_ text: String) -> String {
        DiagnosticRedactor.redact(text)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    package static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
