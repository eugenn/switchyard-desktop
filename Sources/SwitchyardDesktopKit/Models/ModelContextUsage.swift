import Foundation

/// The input of the last served request to one model, including cached tokens.
/// It is a snapshot, never a sum of the session's repeated conversation history.
package struct ModelContextUsage: Equatable, Sendable {
    /// Where the window came from, so the explanation never claims a model
    /// maximum it does not have.
    package enum WindowSource: Equatable, Sendable {
        /// The model's own entry in Codex's account catalog.
        case catalog
        /// The window the running route advertises, below the model's own
        /// maximum. Codex compacts the conversation there, whichever model
        /// serves a turn.
        case route
        /// Codex's limit for this conversation, used when routing has left the
        /// catalog empty.
        case session
    }

    package let inputTokens: Int?
    package let contextWindow: Int?
    package var windowSource: WindowSource = .catalog

    package var fraction: Double? {
        guard let inputTokens, inputTokens >= 0,
              let contextWindow, contextWindow > 0 else { return nil }
        return Double(inputTokens) / Double(contextWindow)
    }

    /// Clamp only the drawing; an over-limit percentage remains visible.
    package var fillFraction: Double { min(max(fraction ?? 0, 0), 1) }

    package var percentage: String {
        fraction?.formatted(.percent.precision(.fractionLength(0))) ?? "—"
    }

    package var tokenLabel: String {
        let used = inputTokens.map(Self.compact) ?? "—"
        let limit = contextWindow.map(Self.compact) ?? "—"
        return "\(used) / \(limit)"
    }

    package var explanation: String {
        guard let inputTokens else {
            return "Context usage unavailable: no input token count for this model's latest request in this conversation."
        }
        guard let contextWindow else {
            return "Latest request: \(inputTokens.formatted()) input tokens. Context window unavailable in the Codex model catalog."
        }
        let source = switch windowSource {
        case .catalog:
            "Window from the current Codex model catalog: the model's maximum when provided, otherwise the default window."
        case .route:
            "Window the route advertises to Codex, below this model's own maximum: Codex compacts the conversation at 95% of it. Turn long context back on in Settings to raise it."
        case .session:
            "Window as Codex applies it to this conversation, the limit it compacts at: 95% of what the route advertises, the rest held back for the reply. switchyard-desktop advertises the largest window every routed model accepts; with none advertised Codex falls back to its own 272k default."
        }
        return "Context: \(percentage) · \(inputTokens.formatted()) of \(contextWindow.formatted()) tokens. Latest request to this model in this conversation; includes cached input, excludes output. \(source)"
    }

    private static func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    /// - Parameter sessionWindow: Codex's own window for this conversation,
    ///   used for a model the catalog does not name.
    /// - Parameter routeWindow: the window the route advertises. A model's
    ///   window never reads above it, since Codex measures the conversation
    ///   against the route's window, not the model's own maximum.
    package static func latest(
        records: [RoutingLogRecord], sessionID: String, contextWindows: [String: Int],
        sessionWindow: Int? = nil, routeWindow: Int? = nil
    ) -> [String: ModelContextUsage] {
        var latest: [String: RoutingLogRecord] = [:]
        // The log is newest first; timestamps also handle out-of-order writes.
        for record in records where record.sessionID == sessionID && !record.isClassifier {
            let id = record.modelIdentity
            if let previous = latest[id] {
                guard let timestamp = record.timestamp,
                      previous.timestamp.map({ timestamp > $0 }) ?? true else { continue }
            }
            latest[id] = record
        }
        return latest.mapValues { record in
            if let window = contextWindows[record.modelIdentity] {
                if let routeWindow, routeWindow > 0, routeWindow < window {
                    return ModelContextUsage(
                        inputTokens: record.contextInputTokens, contextWindow: routeWindow, windowSource: .route)
                }
                return ModelContextUsage(inputTokens: record.contextInputTokens, contextWindow: window)
            }
            return ModelContextUsage(
                inputTokens: record.contextInputTokens,
                contextWindow: sessionWindow.flatMap { $0 > 0 ? $0 : nil },
                windowSource: .session
            )
        }
    }
}
