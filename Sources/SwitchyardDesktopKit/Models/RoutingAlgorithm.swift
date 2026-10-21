import Foundation

/// Native Switchyard routes. Swift configures them; the bundled server executes them.
package enum RoutingAlgorithm: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case auto
    case stageRouter = "stage_router"
    case capability = "capability"
    // Keep the stored value used by older custom-classifier profiles.
    case llmClassifier = "llm_classifier"
    case escalation
    case composite
    case advisor
    case random
    case passthrough
    case noop
    case prefillRouter = "prefill_router"
    case planExecute = "plan_execute"

    package var id: String { rawValue }
    package var serverType: String {
        switch self {
        case .capability, .escalation: "llm_classifier"
        default: rawValue
        }
    }
    package var displayName: String {
        switch self {
        case .auto: "Auto"
        case .stageRouter: "Stage router"
        case .capability: "Capability classifier"
        case .llmClassifier: "Custom classifier"
        case .escalation: "Escalation"
        case .composite: "Composite"
        case .advisor: "Advisor gate"
        case .random: "Random"
        case .passthrough: "Passthrough"
        case .noop: "No-op"
        case .prefillRouter: "Prefill router (optional build)"
        case .planExecute: "Plan → execute"
        }
    }
    package var summary: String {
        switch self {
        case .auto: "Uses Switchyard’s recommended routing preset."
        case .stageRouter: "Scores tool results on every request and switches between Efficient and Capable."
        case .capability: "Uses Switchyard’s built-in capability forecast and probability thresholds."
        case .llmClassifier: "Uses your target descriptions and JSON policy to choose a model group."
        case .escalation: "Judges completed efficient turns and switches to Capable after fresh, consistent failure evidence."
        case .composite: "A classifier picks the starting tier; stage signals can switch it during tool execution."
        case .advisor: "An advisor reviews the executor’s work and can request a redo."
        case .random: "Chooses a target per request with optional weights and a seed."
        case .passthrough: "Always serves the selected target, with optional separate subagent routing."
        case .noop: "Returns OK without calling a model."
        case .prefillRouter: "Requires a server built with prefill-router, its Python dependencies and a trained checkpoint."
        case .planExecute: "Plans on Capable, then permanently hands off to Efficient after the first edit or write."
        }
    }
    package var requiresJudge: Bool {
        [.capability, .llmClassifier, .escalation, .composite, .advisor].contains(self)
    }
    package var hasTierPair: Bool {
        [.auto, .stageRouter, .capability, .escalation, .composite, .planExecute].contains(self)
    }
    package var hasVariableTargets: Bool {
        [.llmClassifier, .random, .prefillRouter].contains(self)
    }
    package var supportsClassifyTrigger: Bool {
        [.capability, .llmClassifier, .composite].contains(self)
    }
}

package enum ClassifyTrigger: String, CaseIterable, Codable, Sendable, Identifiable {
    case everyRequest = "every_request"
    case userTurn = "user_turn"
    case newSession = "new_session"
    package var id: String { rawValue }
    package var displayName: String {
        switch self {
        case .everyRequest: "Every request, including tool continuations"
        case .userTurn: "Each new user message"
        case .newSession: "Once per session"
        }
    }
}
