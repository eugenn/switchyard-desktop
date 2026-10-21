import AppKit
import SwitchyardDesktopKit
import SwiftUI

@main
struct SwitchyardDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: WizardModel
    @State private var monitor: RoutingMonitor

    init() {
        let model = MainActor.assumeIsolated { WizardModel() }
        _model = State(initialValue: model)
        _monitor = State(initialValue: MainActor.assumeIsolated { RoutingMonitor(model: model) })
    }

    var body: some Scene {
        // SwiftUI opens the first Window scene on launch. Keep Statistics first
        // so the app opens on the live activity screen instead of the setup wizard.
        Window("switchyard-desktop — Statistics", id: Self.statisticsWindowID) {
            StatisticsScene(monitor: monitor, appDelegate: appDelegate)
        }
        .defaultSize(width: StatisticsWindow.windowWidth, height: StatisticsWindow.windowHeight)
        // The panes are laid out for one size, so the window is not resizable.
        .windowResizability(.contentSize)

        Window("switchyard-desktop", id: Self.setupWindowID) {
            SetupWindow(model: model, monitor: monitor, appDelegate: appDelegate)
        }
        .defaultSize(width: 960, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .windowList) {
                OpenWindowCommands(setupWindowID: Self.setupWindowID, statisticsWindowID: Self.statisticsWindowID)
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }

    static let setupWindowID = "routing-controls"
    static let statisticsWindowID = "routing-statistics"
}

private struct SetupWindow: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: WizardModel
    let monitor: RoutingMonitor
    let appDelegate: AppDelegate

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(RouterTheme.accent)
                Text("switchyard-desktop").font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 18)
            RouterDivider()
            WizardView(model: model, openStatistics: openStatistics)
        }
        .frame(minWidth: 940, minHeight: 760)
        .background(RouterTheme.win)
        .foregroundStyle(RouterTheme.ink)
        .environment(\.colorScheme, .dark)
        .observeRoutingWindowVisibility()
        .onAppear {
            appDelegate.connect(
                model: model,
                openControls: openHome,
                openActivity: openStatistics,
                openStatistics: openStatistics
            )
        }
        .routingQuitConfirmation(model: model)
    }

    private func openHome() {
        openWindow(id: SwitchyardDesktopApp.setupWindowID)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openStatistics() {
        monitor.pane = .statistics
        openWindow(id: SwitchyardDesktopApp.statisticsWindowID)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct StatisticsScene: View {
    @Environment(\.openWindow) private var openWindow
    let monitor: RoutingMonitor
    let appDelegate: AppDelegate

    var body: some View {
        StatisticsWindow(monitor: monitor, openSetup: openSetup, showsStartControl: true)
            .onAppear {
                appDelegate.connect(
                    model: monitor.model,
                    openControls: openSetup,
                    openActivity: openStatistics,
                    openStatistics: openStatistics
                )
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
    }

    private func openSetup() {
        openWindow(id: SwitchyardDesktopApp.setupWindowID)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openStatistics() {
        monitor.pane = .statistics
        openWindow(id: SwitchyardDesktopApp.statisticsWindowID)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
