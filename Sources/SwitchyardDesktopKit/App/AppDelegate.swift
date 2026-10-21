import AppKit

/// Run as a normal windowed app even when launched straight from the build
/// directory: an unbundled executable starts without a regular activation
/// policy, so it would otherwise show no window and no Dock icon.
///
/// Owns process lifecycle, the menu-bar status item and diagnostic logging.
@MainActor
package final class AppDelegate: NSObject, NSApplicationDelegate {
    private var lifecycle: RoutingLifecycleCoordinator?
    private let statusItem = RoutingStatusItem()

    package override init() {
        super.init()
    }

    package func connect(
        model: WizardModel,
        openControls: @escaping () -> Void,
        openActivity: @escaping () -> Void,
        openStatistics: @escaping () -> Void
    ) {
        if let lifecycle {
            lifecycle.openControls = openControls
            lifecycle.openStatistics = openActivity
            statusItem.onStatistics = openStatistics
            statusItem.onControls = openControls
            return
        }
        let coordinator = RoutingLifecycleCoordinator(
            model: model, statusDisplay: statusItem, openControls: openControls,
            openStatistics: openActivity
        )
        lifecycle = coordinator
        statusItem.onOpen = { [weak coordinator] in coordinator?.reopen() }
        statusItem.onControls = openControls
        statusItem.onStatistics = openStatistics
        statusItem.onStop = { [weak coordinator] in
            Task { await coordinator?.stopRouting() }
        }
        statusItem.onRevealLogs = { AppDelegate.revealLogs() }
        statusItem.onQuit = { NSApp.terminate(nil) }
    }

    package func applicationDidFinishLaunching(_ notification: Notification) {
        Self.reclaimPriorInstance()
        DiagnosticLog.shared.info("app", "switchyard-desktop launched", [
            ("version", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"),
            ("log", DiagnosticLog.shared.url.path),
        ])
        NSApp.setActivationPolicy(.regular)
        installDockIcon()
        // The interface is designed for one dark palette only.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    package func applicationDidBecomeActive(_ notification: Notification) {
        // An unbundled Xcode/SwiftPM launch creates its Dock tile during
        // activation. Reapply the artwork after that transition as well.
        installDockIcon()
    }

    package func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let lifecycle else { return true }
        lifecycle.reopen()
        return false
    }

    package func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let shouldTerminate = lifecycle?.shouldTerminateAfterLastWindowClosed ?? true
        if !shouldTerminate {
            DispatchQueue.main.async {
                guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        }
        return shouldTerminate
    }

    package func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        lifecycle?.requestQuit() == false ? .terminateCancel : .terminateNow
    }

    package func applicationWillTerminate(_ notification: Notification) {
        // Stopping the proxy alone would leave a generated profile pointing at a
        // dead endpoint, so remove it before the process goes.
        lifecycle?.model.cleanUpForTermination()
    }

    /// Shows the user where the durable logs are. The note is written first so
    /// the file always exists to select, even on a launch that never routed.
    package static func revealLogs() {
        let log = DiagnosticLog.shared
        log.info("app", "Revealed the log folder in Finder")
        NSWorkspace.shared.activateFileViewerSelecting([log.url])
    }

    /// A run started from Xcode can leave the previous run alive — most
    /// reliably when it kept a menu-bar presence after the debugger detached.
    /// Without this, that old process keeps the window and Dock tile, so the
    /// build just produced never appears to have run. A packaged `.app` is a
    /// single Launch Services identity already and never needs this.
    private static func reclaimPriorInstance() {
        #if DEBUG
        guard Bundle.main.bundleURL.pathExtension != "app",
              let executablePath = Bundle.main.executablePath
        else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let stopped = PriorInstanceReclaimer().reclaim(executablePath: executablePath, excluding: ownPID)
        for pid in stopped {
            DiagnosticLog.shared.info("app", "Stopped an earlier Xcode launch", [("pid", "\(pid)")])
        }
        #endif
    }

    /// Swift Package launches from Xcode are not app bundles, so macOS cannot
    /// read the bundle's `.icns` file. Load the same artwork from the shared
    /// kit target's resources to keep the Dock icon correct in both launch
    /// modes, for either edition.
    private func installDockIcon() {
        let resources: Bundle?
        if Bundle.main.bundleURL.pathExtension == "app" {
            resources = Bundle(url: Bundle.main.bundleURL.appendingPathComponent(
                "Contents/Resources/switchyard-desktop_SwitchyardDesktopKit.bundle"
            ))
        } else {
            resources = Bundle.module
        }
        guard
            let url = resources?.url(forResource: "AppIcon", withExtension: "png"),
            let icon = NSImage(contentsOf: url)
        else {
            return
        }

        NSApp.applicationIconImage = icon
    }
}
