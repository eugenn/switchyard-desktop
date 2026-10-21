import AppKit
import SwiftUI

/// The "routing is active, stop before quitting" dialog is identical in both
/// editions, so it lives here rather than being copied into each app's entry
/// point.
package struct RoutingQuitConfirmation: ViewModifier {
    @Bindable var model: WizardModel

    package func body(content: Content) -> some View {
        content.confirmationDialog(
            "Routing is active", isPresented: $model.shouldConfirmQuit, titleVisibility: .visible
        ) {
            Button("Stop and Quit", role: .destructive) {
                Task { if await model.revertAndQuit() { NSApp.terminate(nil) } }
            }
            Button("Cancel", role: .cancel, action: model.cancelQuit)
        } message: {
            Text(
                """
                switchyard-desktop will remove the Codex profile it generated and stop its servers. \
                Your own Codex configuration is not affected.
                """
            )
        }
    }
}

package extension View {
    func routingQuitConfirmation(model: WizardModel) -> some View {
        modifier(RoutingQuitConfirmation(model: model))
    }
}
