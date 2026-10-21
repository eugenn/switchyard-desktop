import Foundation

/// Drains one child server's stdout and stderr for as long as it runs, redacts
/// every line, and appends it to a durable file beside the app's own log.
///
/// Draining is not optional. A pipe nobody reads holds about 64 KB, after
/// which the child blocks inside `write` and never returns — from the outside
/// that looks exactly like a proxy that has stopped answering requests, with
/// no evidence left behind to explain it. This type reads continuously so the
/// server can never be stalled by its own logging, and keeps what it read.
package final class ChildOutputRecorder: @unchecked Sendable {
    /// Roughly the last screenful, kept in memory for the failure the UI shows.
    package static let memoryLimit = 4_000
    /// Server output is far more voluminous than lifecycle events, so it gets
    /// its own, larger budget.
    package static let fileByteLimit = 2 * 1_024 * 1_024
    /// One absurd line cannot be allowed to hold the whole buffer.
    package static let lineLimit = 4_000

    /// Hand this to `Process.standardOutput` and `.standardError`.
    package let pipe = Pipe()

    private let url: URL
    /// Guards the buffers and the file.
    private let lock = NSLock()
    /// Guards reading from the pipe, so the background handler and `finish()`
    /// cannot each take half of the child's last words.
    private let readLock = NSLock()
    private var pending = Data()
    private var recent = ""

    package init(url: URL) {
        self.url = url
    }

    /// Starts draining. `banner` names the run that follows it in the file.
    package func begin(banner: String) {
        write("\n=== \(DiagnosticLog.timestamp()) \(banner) ===\n")
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            self.readLock.lock()
            defer { self.readLock.unlock() }
            let data = handle.availableData
            guard !data.isEmpty else {
                // The child closed its end. Left installed, this handler would
                // spin on end-of-file for as long as the app runs.
                handle.readabilityHandler = nil
                self.flushPending()
                return
            }
            self.consume(data)
        }
    }

    /// Stops draining and flushes whatever the child wrote last. Call it only
    /// once the child has exited: a read of a live child's pipe blocks until
    /// it writes something, and this waits for any read already in flight.
    package func finish(banner: String? = nil) {
        let handle = pipe.fileHandleForReading
        // Taken before the last reads: a handler already running holds this
        // lock, and whatever it read is recorded before this returns.
        readLock.lock()
        handle.readabilityHandler = nil
        while case let data = handle.availableData, !data.isEmpty {
            consume(data)
        }
        flushPending()
        readLock.unlock()
        if let banner {
            write("=== \(DiagnosticLog.timestamp()) \(banner) ===\n")
        }
        try? handle.close()
        try? pipe.fileHandleForWriting.close()
    }

    /// The parent's copy of the write end, closed once the child owns its own,
    /// so end-of-output is observable here.
    package func closeWriteEnd() {
        try? pipe.fileHandleForWriting.close()
    }

    /// The recent tail, already redacted, for surfacing a failure in the UI.
    package var recentText: String {
        lock.lock()
        defer { lock.unlock() }
        return recent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Draining

    private func consume(_ data: Data) {
        var raw: [Data] = []
        lock.lock()
        pending.append(data)
        while let breakIndex = pending.firstIndex(of: UInt8(ascii: "\n")) {
            raw.append(pending[pending.startIndex..<breakIndex])
            pending = pending[pending.index(after: breakIndex)...]
        }
        // A child that writes no newline at all must not grow this without bound.
        if pending.count > Self.lineLimit {
            raw.append(pending)
            pending = Data()
        }
        lock.unlock()
        // Redaction is regex work: it stays outside the lock so a chatty server
        // cannot serialise itself behind it.
        record(raw.map(Self.line(from:)))
    }

    private func flushPending() {
        lock.lock()
        let remainder = pending
        pending = Data()
        lock.unlock()
        guard !remainder.isEmpty else { return }
        record([Self.line(from: remainder)])
    }

    private static func line(from data: Data) -> String {
        let text = String(decoding: Array(data.prefix(lineLimit)), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "" : DiagnosticRedactor.redact(text)
    }

    private func record(_ lines: [String]) {
        let kept = lines.filter { !$0.isEmpty }
        guard !kept.isEmpty else { return }
        let text = kept.joined(separator: "\n") + "\n"
        write(text)
        lock.lock()
        recent += text
        if recent.count > Self.memoryLimit {
            recent = String(recent.suffix(Self.memoryLimit))
        }
        lock.unlock()
    }

    private func write(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        DiagnosticFile.append(text, to: url, byteLimit: Self.fileByteLimit)
    }
}
