import Foundation
import Observation

package struct RoutingStatusPresentation: Equatable {
    package let isVisible: Bool
    package let title: String
    package let needsRecovery: Bool
    /// A leftover to look at, or a generated profile that drifted away from the
    /// running route: either way the icon warns and a click opens the controls.
    package let needsAttention: Bool
    package let canStop: Bool
}

@MainActor
package protocol RoutingStatusDisplaying: AnyObject {
    func update(_ presentation: RoutingStatusPresentation)
}

/// Owned by the application delegate, not by the window that can be closed.
@MainActor
package final class RoutingLifecycleCoordinator {
    package let model: WizardModel
    private let statusDisplay: any RoutingStatusDisplaying
    package var openControls: () -> Void
    package var openStatistics: () -> Void

    package init(
        model: WizardModel,
        statusDisplay: any RoutingStatusDisplaying,
        openControls: @escaping () -> Void,
        openStatistics: @escaping () -> Void = {}
    ) {
        self.model = model
        self.statusDisplay = statusDisplay
        self.openControls = openControls
        self.openStatistics = openStatistics
        observeStatus()
    }

    package var shouldTerminateAfterLastWindowClosed: Bool {
        !model.isApplied && !model.processManager.status.isRunning
            && !model.isBusy && !model.recoveryState.needsAttention
    }

    package var presentation: RoutingStatusPresentation {
        let running = model.processManager.status.isRunning
        let needsRecovery = model.recoveryState.needsAttention || (model.isApplied && !running)
        let visible = model.isApplied || running || needsRecovery
        let title: String
        if needsRecovery {
            title = "Recovery required - open controls"
        } else if let drift = model.codexDrift {
            // The window is usually closed when another client rewrites the
            // Codex selection, so the icon is the only place left to say it.
            title = drift.statusTitle
        } else if model.isBusy {
            title = "Updating routing..."
        } else if case .running(_, let port) = model.processManager.status {
            title = "Routing active on port \(port)"
        } else {
            title = "Routing stopped"
        }
        return RoutingStatusPresentation(
            isVisible: visible,
            title: title,
            needsRecovery: needsRecovery,
            needsAttention: needsRecovery || model.codexDrift != nil,
            // Also offered when the proxy is already gone but a generated
            // profile is not: that is exactly what Stop removes.
            canStop: (running || model.isApplied) && !model.isBusy
        )
    }

    package func reopenControls() {
        if presentation.isVisible { model.step = .confirm }
        openControls()
    }

    /// The ordinary app/menu-bar click opens live activity. Configuration is
    /// an explicit destination, except when the route needs recovery or the
    /// generated Codex profile drifted: both are handled in the controls.
    package func reopen() {
        if model.processManager.status.isRunning && !presentation.needsAttention {
            openStatistics()
        } else {
            reopenControls()
        }
    }

    /// Stopping also removes the generated Codex profile: leaving it would point
    /// a routed session at an endpoint that is no longer there.
    @discardableResult
    package func stopRouting() async -> Bool {
        let stopped = await model.revert()
        statusDisplay.update(presentation)
        reopenControls()
        return stopped
    }

    package func requestQuit() -> Bool {
        let allowed = model.requestQuit()
        if !allowed { reopenControls() }
        return allowed
    }

    private func observeStatus() {
        let snapshot = withObservationTracking {
            presentation
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeStatus()
            }
        }
        statusDisplay.update(snapshot)
    }
}
