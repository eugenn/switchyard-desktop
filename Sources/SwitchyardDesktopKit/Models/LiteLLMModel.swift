import Foundation

/// One entry in the bundled LiteLLM's model list: the name callers ask for, and
/// the ChatGPT model that answers it.
///
/// The two differ when the judge needs an endpoint of its own. Switchyard keys
/// a route's execution by model id and rejects one id reached through two
/// `[llm_clients]` entries, so a judge that talks to LiteLLM while the served
/// turns go straight to ChatGPT asks for the same model under a name of its
/// own.
package struct LiteLLMModel: Equatable, Sendable, Hashable {
    /// The name Switchyard sends, and the `model_name` LiteLLM publishes.
    package let name: String
    /// The ChatGPT model LiteLLM calls for it.
    package let upstreamModel: String

    package init(_ name: String, servedBy upstreamModel: String? = nil) {
        self.name = name
        self.upstreamModel = upstreamModel ?? name
    }
}

/// A plain name is a model served under its own name.
extension LiteLLMModel: ExpressibleByStringLiteral {
    package init(stringLiteral value: String) {
        self.init(value)
    }
}
