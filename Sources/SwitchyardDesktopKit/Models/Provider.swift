import Foundation

/// An upstream LLM provider the wizard can configure routing for.
///
/// Only `.codex` is selectable in the MVP; the other cases exist so the provider
/// step can show them as visibly disabled ("coming soon") without branching logic.
package enum Provider: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case anthropic
    case gemini

    package var id: String { rawValue }

    package var displayName: String {
        switch self {
        case .codex: "OpenAI Codex"
        case .anthropic: "Anthropic Claude"
        case .gemini: "Google Gemini"
        }
    }

    /// Whether the wizard can currently generate a working configuration for this provider.
    package var isSelectable: Bool {
        self == .codex
    }

    /// Default upstream API base URL for the generated Switchyard `llm_clients` entry.
    ///
    /// The app owns a local LiteLLM proxy that manages the ChatGPT OAuth session.
    package var defaultUpstreamBaseURL: String {
        switch self {
        case .codex: "http://127.0.0.1:4101/v1"
        case .anthropic: "https://api.anthropic.com"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        }
    }

    /// Switchyard `llm_clients.<name>.format` value for this provider.
    /// Codex CLI and Desktop speak the Responses API (`wire_api = "responses"`).
    package var wireFormat: String {
        switch self {
        case .codex: "openai_responses"
        case .anthropic: "anthropic_messages"
        case .gemini: "openai_chat"
        }
    }

    /// Name of the generated `[llm_clients.<name>]` entry.
    package var clientName: String {
        switch self {
        case .codex: "openai"
        case .anthropic: "anthropic"
        case .gemini: "gemini"
        }
    }

    /// `wire_api` value Codex needs in `~/.codex/config.toml` for this provider's proxy route.
    package var codexWireAPI: String {
        switch self {
        case .codex: "responses"
        case .anthropic, .gemini: "chat"
        }
    }
}
