import AppKit
import Foundation

/// The few facts this app needs about another running process to decide
/// whether it is an earlier launch of this same executable, and to ask it to
/// quit. Split out so the decision can be tested without leaving real
/// processes behind.
package protocol RunningInstanceInspecting: Sendable {
    /// PIDs of other running applications whose executable matches `executablePath`.
    func otherInstances(executablePath: String, excluding pid: Int32) -> [Int32]
    /// The ordinary "Quit" request: routes through the target's own
    /// `applicationShouldTerminate`/`applicationWillTerminate`, so it still
    /// gets a chance to remove the Codex profile it generated.
    func requestTermination(_ pid: Int32)
    /// Only used when a process ignores the request above.
    func forceTermination(_ pid: Int32)
    func isAlive(_ pid: Int32) -> Bool
}

/// Stops an earlier, still-running launch of this exact debug executable.
///
/// Xcode does not always replace a previous run before starting a new one —
/// most reliably when the app keeps a menu-bar presence alive after the
/// debugger detaches. Left alone, that old process still owns the window and
/// Dock tile, so the code just built never appears to have run. Scoped to
/// unbundled debug launches: a packaged `.app` is one Launch Services identity
/// already and never collides with itself this way.
package struct PriorInstanceReclaimer: Sendable {
    private let inspector: any RunningInstanceInspecting
    private let terminationTimeout: TimeInterval
    private let killTimeout: TimeInterval
    private let pollInterval: TimeInterval

    package init(
        inspector: any RunningInstanceInspecting = WorkspaceRunningInstanceInspector(),
        terminationTimeout: TimeInterval = 3,
        killTimeout: TimeInterval = 2,
        pollInterval: TimeInterval = 0.05
    ) {
        self.inspector = inspector
        self.terminationTimeout = terminationTimeout
        self.killTimeout = killTimeout
        self.pollInterval = pollInterval
    }

    /// Asks every other process running `executablePath` to quit, waits for
    /// its ordinary shutdown, and only forces it closed if it ignores that.
    /// Returns the PIDs that were actually stopped.
    package func reclaim(executablePath: String, excluding ownPID: Int32) -> [Int32] {
        var stopped: [Int32] = []
        for pid in inspector.otherInstances(executablePath: executablePath, excluding: ownPID) {
            inspector.requestTermination(pid)
            if waitForExit(pid, timeout: terminationTimeout) {
                stopped.append(pid)
                continue
            }
            inspector.forceTermination(pid)
            if waitForExit(pid, timeout: killTimeout) {
                stopped.append(pid)
            }
        }
        return stopped
    }

    private func waitForExit(_ pid: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !inspector.isAlive(pid) { return true }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return !inspector.isAlive(pid)
    }
}

/// Looks up other instances through `NSWorkspace`/`NSRunningApplication`,
/// which only ever lists processes that reached a regular activation policy
/// — exactly the ones that could be mistaken for the app just launched.
package struct WorkspaceRunningInstanceInspector: RunningInstanceInspecting {
    package func otherInstances(executablePath: String, excluding pid: Int32) -> [Int32] {
        let target = URL(fileURLWithPath: executablePath).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.compactMap { app -> Int32? in
            guard app.processIdentifier != pid,
                  let candidate = app.executableURL?.standardizedFileURL.path,
                  candidate == target
            else { return nil }
            return app.processIdentifier
        }
    }

    package func requestTermination(_ pid: Int32) {
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    package func forceTermination(_ pid: Int32) {
        NSRunningApplication(processIdentifier: pid)?.forceTerminate()
    }

    package func isAlive(_ pid: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated
    }
}
