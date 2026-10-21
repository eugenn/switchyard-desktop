import Darwin
import Foundation

/// Finds command-line tools the way the user's own shell would.
///
/// An app launched from Finder, Xcode or launchd inherits a minimal `PATH`
/// (`/usr/bin:/bin:/usr/sbin:/sbin`), so anything installed outside those
/// directories is invisible to it — the same `codex` that works in a Terminal
/// reads as "not found" in the app. Rather than hardcoding any package
/// manager's location, this asks the user's login shell for its own `PATH`,
/// which is correct whichever way the tool was installed.
package enum LaunchEnvironment {
    /// Last-resort candidates for when the login shell cannot be asked: the
    /// POSIX system directories, the standard local prefix, and the two
    /// per-user `bin` directories macOS tools conventionally use. No package
    /// manager's path is assumed — those arrive through the login shell's own
    /// `PATH`, whichever manager (or manual install) put them there.
    package static let conventionalDirectories = [
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
        "/usr/local/bin",
        "~/.local/bin",
        "~/bin",
    ]

    /// Directories searched for a tool, in order, without duplicates.
    package static var searchPaths: [String] {
        if UserDataLocations.isUnderTest {
            return mergedSearchPaths(processPath: nil, loginShellPath: nil)
        }
        return Cache.shared.searchPaths {
            mergedSearchPaths(
                processPath: ProcessInfo.processInfo.environment["PATH"],
                loginShellPath: loginShellPath()
            )
        }
    }

    /// An absolute path to `name`, or `nil` when no directory holds it.
    package static func locate(_ name: String, searchPaths: [String]? = nil) -> URL? {
        let fileManager = FileManager.default
        for directory in searchPaths ?? self.searchPaths {
            let candidate = URL(fileURLWithPath: expanded(directory))
                .appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// `base` with a `PATH` the located tool's own child processes can use —
    /// the Codex CLI shells out to node and git.
    package static func childEnvironment(
        _ base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        environment["PATH"] = searchPaths.map(expanded).joined(separator: ":")
        return environment
    }

    /// Process `PATH` first (an explicitly launched shell knows best), then the
    /// login shell's, then the conventional directories.
    package static func mergedSearchPaths(
        processPath: String?,
        loginShellPath: String?,
        conventional: [String] = LaunchEnvironment.conventionalDirectories
    ) -> [String] {
        var merged: [String] = []
        var seen: Set<String> = []

        for group in [processPath, loginShellPath] {
            for directory in (group ?? "").split(separator: ":").map(String.init)
            where !directory.isEmpty {
                if seen.insert(expanded(directory)).inserted { merged.append(directory) }
            }
        }
        for directory in conventional where seen.insert(expanded(directory)).inserted {
            merged.append(directory)
        }
        return merged
    }

    // MARK: - Login shell

    /// `$PATH` as the user's own login shell reports it. Nil when the shell is
    /// missing, fails, or takes too long — the conventional directories then
    /// have to be enough.
    package static func loginShellPath(timeout: TimeInterval = 4) -> String? {
        // A login shell reads user-owned startup files and may execute arbitrary
        // local setup. Tests use conventional paths and injected executables.
        guard !UserDataLocations.isUnderTest else { return nil }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Login + interactive-free: reads the profile that defines PATH.
        process.arguments = ["-lc", "printf %s \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = read(output.fileHandleForReading, deadline: Date().addingTimeInterval(timeout))
        if process.isRunning { process.terminate() }
        process.waitUntilExit()

        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func read(_ handle: FileHandle, deadline: Date) -> Data {
        var data = Data()
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return data }
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Int32((remaining * 1_000).rounded(.up))) > 0 else {
                return data
            }
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return data }
            data.append(chunk)
        }
    }

    private static func expanded(_ directory: String) -> String {
        if directory == "~" { return UserDataLocations.home.path }
        if directory.hasPrefix("~/") {
            return UserDataLocations.home.appendingPathComponent(String(directory.dropFirst(2))).path
        }
        if UserDataLocations.isUnderTest { return directory }
        return (directory as NSString).expandingTildeInPath
    }

    /// Asking the login shell costs a process launch, so the answer is resolved
    /// once and shared.
    private final class Cache: @unchecked Sendable {
        package static let shared = Cache()
        private let lock = NSLock()
        private var stored: [String]?

        package func searchPaths(_ resolve: () -> [String]) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            if let stored { return stored }
            let resolved = resolve()
            stored = resolved
            return resolved
        }
    }
}
