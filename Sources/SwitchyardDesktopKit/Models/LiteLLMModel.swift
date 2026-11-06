import Foundation

/// One entry in the bundled LiteLLM's model list: the name callers ask for, and
/// the ChatGPT model that answers it.
///
/// Aliases remain supported for explicitly named gateway models; current routes
/// use provider model IDs and keep judge settings on a separate target.
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
