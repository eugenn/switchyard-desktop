import Foundation

/// A child process this app started, written down so a later launch can
/// recognise it. Nothing but identifiers and paths is recorded.
///
/// A crash, a Force Quit or a log-out kills the app without running any of its
/// shutdown code, and the servers it started keep their loopback ports. Without
/// this record the next launch has no way to tell its own abandoned child from
/// an unrelated program that happens to hold port 4100, so it can only refuse
/// to start and leave the user with a terminal and `kill`.
package struct ManagedProcessRecord: Codable, Equatable, Sendable {
    package let name: String
    package let pid: Int32
    package let port: Int
    package let executablePath: String
    package let startedAt: Date
}

@MainActor
package protocol ManagedProcessRecording: AnyObject {
    func records() -> [ManagedProcessRecord]
    func record(_ record: ManagedProcessRecord)
    func forget(pid: Int32)
}

/// Best-effort persistence. Routing must never fail to start because this
/// bookkeeping file could not be written, so every failure is swallowed here
/// and the only cost is a leftover the next launch cannot attribute.
@MainActor
package final class ManagedProcessRegistry: ManagedProcessRecording {
    package static var defaultURL: URL {
        SwitchyardConfigWriter.supportDirectory
            .appendingPathComponent("managed-processes.json")
    }

    /// The registry every manager uses unless one is injected.
    ///
    /// Under test it keeps nothing. Tests run in parallel inside one process,
    /// and a record written by a test that starts a real server would let
    /// another test's reclaim stop the server it is still using.
    package static func standard() -> any ManagedProcessRecording {
        DiagnosticLog.isUnderTest ? ForgetfulProcessRegistry() : ManagedProcessRegistry()
    }

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    package init(fileURL: URL = ManagedProcessRegistry.defaultURL) {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
    }

    package func records() -> [ManagedProcessRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([ManagedProcessRecord].self, from: data)) ?? []
    }

    package func record(_ record: ManagedProcessRecord) {
        var kept = records().filter { $0.pid != record.pid }
        kept.append(record)
        write(kept)
    }

    package func forget(pid: Int32) {
        let kept = records().filter { $0.pid != pid }
        guard kept.count != records().count else { return }
        write(kept)
    }

    private func write(_ records: [ManagedProcessRecord]) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Remembers nothing, so no leftover is ever attributed to this run.
@MainActor
package final class ForgetfulProcessRegistry: ManagedProcessRecording {
    package func records() -> [ManagedProcessRecord] { [] }
    package func record(_ record: ManagedProcessRecord) {}
    package func forget(pid: Int32) {}
}
