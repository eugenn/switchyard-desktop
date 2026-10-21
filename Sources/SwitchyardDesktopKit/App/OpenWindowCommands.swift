import AppKit
import SwiftUI

/// Menu entries so the setup and statistics windows can be reopened after
/// being closed. Shared by both editions; only the window ids differ.
package struct OpenWindowCommands: View {
    @Environment(\.openWindow) private var openWindow
    private let setupWindowID: String
    private let statisticsWindowID: String

    package init(setupWindowID: String, statisticsWindowID: String) {
        self.setupWindowID = setupWindowID
        self.statisticsWindowID = statisticsWindowID
    }

    package var body: some View {
        Button("switchyard-desktop") {
            openWindow(id: setupWindowID)
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("1", modifiers: .command)
        Button("Routing Statistics") {
            openWindow(id: statisticsWindowID)
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("2", modifiers: .command)
    }
}
