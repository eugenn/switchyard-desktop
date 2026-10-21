import Darwin
import Foundation

/// The few facts about a running process this app needs in order to decide
/// whether it may stop it. Split out so the decision can be tested without
/// leaving real processes behind.
package protocol ProcessInspecting: Sendable {
    func isAlive(_ pid: Int32) -> Bool
    /// Absolute path of the running executable, or nil when the process is gone
    /// or belongs to another user.
    func executablePath(of pid: Int32) -> String?
    /// PIDs listening on the given loopback port.
    func listeningPIDs(port: Int) -> [Int32]
    func terminate(_ pid: Int32)
    func forceKill(_ pid: Int32)
}

/// What a reclaim attempt actually changed, in the words the user reads.
///
/// Kept separate from the outcomes themselves so the same attempt can both
/// explain a freed port in the log and, when a port stays held, say which
/// program holds it instead of leaving "address in use" as the whole story.
package struct LeftoverReclaimReport: Equatable, Sendable {
    package private(set) var reclaimed: [String] = []
    package private(set) var blocked: [String] = []

    package var isEmpty: Bool { reclaimed.isEmpty && blocked.isEmpty }
    package var freedSomething: Bool { !reclaimed.isEmpty }

    package mutating func add(_ outcome: LeftoverProcessReclaimer.Outcome, port: Int) {
        switch outcome {
        case .reclaimed(let name, let pid, let forced):
            reclaimed.append(
                forced
                    ? "\(name) (pid \(pid)) from an earlier run ignored a stop request and was "
                        + "killed; port \(port) is free again."
                    : "\(name) (pid \(pid)) was left running by an earlier run and was stopped; "
                        + "port \(port) is free again."
            )
        case .foreign(let heldPort, let pid, let path):
            let program = path.map { " (\($0))" } ?? ""
            blocked.append(
                "Port \(heldPort) is held by pid \(pid)\(program), which switchyard-desktop did not "
                    + "start. Quit it or choose another port."
            )
        case .survived(let name, let pid):
            blocked.append(
                "\(name) (pid \(pid)) from an earlier run did not stop and still holds port "
                    + "\(port). Stop it and try again."
            )
        case .vanished, .reused:
            break
        }
    }
}

/// Stops servers this app started and then lost track of.
///
/// The rule it enforces is identity, not convenience: a process is stopped only
/// when the app recorded starting it, or when it holds a port the app is about
/// to use *and* runs one of the app's own bundled executables. Anything else
/// keeps its port and is reported by name, because a router that kills an
/// unrelated program to free 4100 is worse than one that refuses to start.
package struct LeftoverProcessReclaimer: Sendable {
    package enum Outcome: Equatable, Sendable {
        /// Stopped; `forced` means it ignored SIGTERM and was killed.
        case reclaimed(name: String, pid: Int32, forced: Bool)
        /// Already gone. The record is stale and can be dropped.
        case vanished(pid: Int32)
        /// The PID is alive but now runs something else: macOS reused it.
        case reused(pid: Int32)
        /// The port belongs to a program this app did not start.
        case foreign(port: Int, pid: Int32, path: String?)
        /// Refused both signals, which the caller must report rather than hide.
        case survived(name: String, pid: Int32)

        /// Whether the record for this PID no longer describes anything.
        package var clearsRecord: Bool {
            switch self {
            case .reclaimed, .vanished, .reused: return true
            case .foreign, .survived: return false
            }
        }

        package var freedSomething: Bool {
            if case .reclaimed = self { return true }
            return false
        }
    }

    private let inspector: any ProcessInspecting
    private let terminationTimeout: Duration
    private let killTimeout: Duration
    private let pollInterval: Duration

    package init(
        inspector: any ProcessInspecting = SystemProcessInspector(),
        terminationTimeout: Duration = .seconds(3),
        killTimeout: Duration = .seconds(2),
        pollInterval: Duration = .milliseconds(50)
    ) {
        self.inspector = inspector
        self.terminationTimeout = terminationTimeout
        self.killTimeout = killTimeout
        self.pollInterval = pollInterval
    }

    /// Stops the children a previous run recorded and never got to stop.
    ///
    /// A recorded PID whose executable no longer matches is left alone: after a
    /// reboot or a long uptime that number belongs to someone else.
    package func reclaim(
        records: [ManagedProcessRecord],
        excluding liveOwnPIDs: Set<Int32> = []
    ) async -> [(record: ManagedProcessRecord, outcome: Outcome)] {
        var outcomes: [(ManagedProcessRecord, Outcome)] = []
        for record in records where !liveOwnPIDs.contains(record.pid) {
            guard record.pid > 1 else {
                outcomes.append((record, .vanished(pid: record.pid)))
                continue
            }
            guard inspector.isAlive(record.pid) else {
                outcomes.append((record, .vanished(pid: record.pid)))
                continue
            }
            guard matches(pid: record.pid, executable: record.executablePath) else {
                outcomes.append((record, .reused(pid: record.pid)))
                continue
            }
            outcomes.append((record, await stop(pid: record.pid, name: record.name)))
        }
        return outcomes
    }

    /// Frees a port still held by one of this app's own executables.
    ///
    /// Used when the recorded PIDs are unavailable — an upgrade from a build
    /// that kept no record, or a deleted support file — so identity comes from
    /// the executable behind the listening socket instead.
    package func reclaimPort(
        _ port: Int,
        name: String,
        ownedExecutables: [String],
        excluding liveOwnPIDs: Set<Int32> = []
    ) async -> [Outcome] {
        let owned = Set(ownedExecutables.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        var outcomes: [Outcome] = []
        for pid in inspector.listeningPIDs(port: port) where pid > 1 && !liveOwnPIDs.contains(pid) {
            let path = inspector.executablePath(of: pid)
            guard let path, owned.contains(URL(fileURLWithPath: path).standardizedFileURL.path) else {
                outcomes.append(.foreign(port: port, pid: pid, path: path))
                continue
            }
            outcomes.append(await stop(pid: pid, name: name))
        }
        return outcomes
    }

    /// Who holds a port, for a message that names it instead of asking the user
    /// to go find out.
    package func holder(ofPort port: Int) -> (pid: Int32, path: String?)? {
        guard let pid = inspector.listeningPIDs(port: port).first else { return nil }
        return (pid, inspector.executablePath(of: pid))
    }

    /// A socket is released by the kernel slightly after its owner dies, so a
    /// start that follows a reclaim immediately can still see the port busy.
    package func waitForPortToClear(
        host: String,
        port: Int,
        timeout: Duration = .seconds(3),
        isAvailable: @Sendable (String, Int) -> Bool = RoutingReadinessChecker.isPortAvailable
    ) async -> Bool {
        var waited = Duration.zero
        while waited < timeout {
            if isAvailable(host, port) { return true }
            try? await Task.sleep(for: pollInterval)
            waited += pollInterval
        }
        return isAvailable(host, port)
    }

    private func matches(pid: Int32, executable: String) -> Bool {
        guard let path = inspector.executablePath(of: pid) else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.path
            == URL(fileURLWithPath: executable).standardizedFileURL.path
    }

    private func stop(pid: Int32, name: String) async -> Outcome {
        inspector.terminate(pid)
        if await waitForExit(pid, timeout: terminationTimeout) {
            return .reclaimed(name: name, pid: pid, forced: false)
        }
        inspector.forceKill(pid)
        if await waitForExit(pid, timeout: killTimeout) {
            return .reclaimed(name: name, pid: pid, forced: true)
        }
        return .survived(name: name, pid: pid)
    }

    private func waitForExit(_ pid: Int32, timeout: Duration) async -> Bool {
        var waited = Duration.zero
        while waited < timeout {
            if !inspector.isAlive(pid) { return true }
            try? await Task.sleep(for: pollInterval)
            waited += pollInterval
        }
        return !inspector.isAlive(pid)
    }
}

/// Reads and signals real processes owned by the current user.
package struct SystemProcessInspector: ProcessInspecting {
    private static let lsofPath = "/usr/sbin/lsof"

    package func isAlive(_ pid: Int32) -> Bool {
        // EPERM means the process exists but is not ours to signal; a leftover
        // of this app always is, so it never reaches the kill calls below.
        kill(pid, 0) == 0 || errno == EPERM
    }

    package func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 2)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    package func listeningPIDs(port: Int) -> [Int32] {
        // A unit test must not be able to signal a server the developer is
        // running on 4100; the reclaimer's own tests inject their own inspector.
        guard !DiagnosticLog.isUnderTest else { return [] }
        guard FileManager.default.isExecutableFile(atPath: Self.lsofPath) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.lsofPath)
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    package func terminate(_ pid: Int32) {
        guard pid > 1 else { return }
        kill(pid, SIGTERM)
    }

    package func forceKill(_ pid: Int32) {
        guard pid > 1 else { return }
        kill(pid, SIGKILL)
    }
}
