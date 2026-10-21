import Foundation

/// What the generated Codex profile layer selects at this moment: the two keys
/// Start writes into `$CODEX_HOME/switchyard-desktop.config.toml`.
///
/// Only this app writes that file, so the selection normally never moves. It can
/// still be edited or deleted by hand, and a session started with
/// `codex --profile switchyard-desktop` then asks the proxy for a model the running
/// route does not serve, or bypasses the proxy entirely.
package struct CodexRouteSelection: Equatable, Sendable {
    package let model: String?
    package let provider: String?

    /// Whether the layer still sends requests to the provider block this app
    /// owns, whatever model it asks that provider for.
    package var selectsManagedProvider: Bool { provider == CodexProfileWriter.providerKey }

    /// How the file differs from the route this app installed, if it does.
    package func drift(routeID: String) -> CodexRouteDrift? {
        guard selectsManagedProvider else { return .providerReplaced(selected: provider) }
        guard model != routeID else { return nil }
        return .modelReplaced(selected: model, routeID: routeID)
    }
}

/// A change made to this app's profile layer while its route was active. Each
/// form breaks a routed Codex session, and each is repaired by generating the
/// file again.
package enum CodexRouteDrift: Equatable, Sendable {
    /// The generated file is no longer on disk, so `--profile switchyard-desktop`
    /// fails to resolve a route at all.
    case profileMissing
    /// The layer still points at the proxy but asks it for a different model.
    case modelReplaced(selected: String?, routeID: String)
    /// The layer was pointed at another provider, so the proxy is bypassed.
    case providerReplaced(selected: String?)

    package var title: String {
        switch self {
        case .profileMissing: "The Codex profile switchyard-desktop generated is gone"
        case .modelReplaced: "The Codex profile asks for a model this route does not serve"
        case .providerReplaced: "The Codex profile no longer points at switchyard-desktop"
        }
    }

    package var message: String {
        switch self {
        case .profileMissing:
            return """
                Routing is still running, but the file it wrote for Codex is no longer there. \
                Sessions started with `\(CodexLocations.launchCommand)` cannot find the route \
                until the file is written again. Nothing else in your Codex setup is affected.
                """
        case .modelReplaced(let selected, let routeID):
            return """
                `model` in the generated Codex profile now reads \(quoted(selected)). Routing is \
                still running and serves only "\(routeID)", so a routed session fails with \
                "No route registered for model \(selected ?? "…")" until the file is written \
                back. Naming a model there does not select a role either: this route picks the \
                model for each turn.
                """
        case .providerReplaced(let selected):
            return """
                The generated Codex profile now selects the provider \(quoted(selected)), so a \
                routed session goes straight to it and skips the running route. Write the \
                profile again, or stop routing and remove it.
                """
        }
    }

    /// The label of the action that generates the file again.
    package var repairTitle: String {
        switch self {
        case .profileMissing: "Write the profile again"
        case .modelReplaced: "Use the route again"
        case .providerReplaced: "Point the profile back"
        }
    }

    /// Short form for the status-bar item, which has one line.
    package var statusTitle: String {
        switch self {
        case .profileMissing: "Codex profile missing - open controls"
        case .modelReplaced: "Codex profile selects another model - open controls"
        case .providerReplaced: "Codex profile bypasses switchyard-desktop - open controls"
        }
    }

    private func quoted(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "an unset value" }
        return "\"\(value)\""
    }
}
