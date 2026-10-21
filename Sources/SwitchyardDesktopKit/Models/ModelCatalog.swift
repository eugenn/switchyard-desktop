import Foundation

/// The list of model ids offered on the model step: a built-in set plus anything
/// the user adds. Phase 1 has no live subscription lookup — the catalog is static
/// and user-editable (see design.md).
package struct ModelCatalog: Codable, Equatable, Sendable {
    /// Ids shipped with the app for a provider, shown first and always offered.
    package private(set) var builtIn: [String]
    /// Ids the user typed in themselves.
    package private(set) var custom: [String]
    /// Built-in ids the user removed from view.
    package private(set) var hidden: Set<String>

    package init(builtIn: [String], custom: [String] = [], hidden: Set<String> = []) {
        self.builtIn = builtIn
        self.custom = custom
        self.hidden = hidden
    }

    /// Everything the user should see, built-ins first, no duplicates.
    package var entries: [String] {
        builtIn.filter { !hidden.contains($0) } + custom
    }

    /// Adds a custom id. Trims whitespace; ignores blanks and ids already present.
    /// Re-adding a previously removed built-in un-hides it instead of duplicating it.
    package mutating func add(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if builtIn.contains(trimmed) {
            hidden.remove(trimmed)
            return
        }
        guard !custom.contains(trimmed) else { return }
        custom.append(trimmed)
    }

    /// Removes an id from the catalog. Custom ids are dropped; built-ins are hidden
    /// so they can come back if the user re-adds them.
    package mutating func remove(_ id: String) {
        if let index = custom.firstIndex(of: id) {
            custom.remove(at: index)
            return
        }
        if builtIn.contains(id) {
            hidden.insert(id)
        }
    }

    /// Built-in catalog for a provider.
    package static func builtIn(for provider: Provider) -> ModelCatalog {
        switch provider {
        case .codex:
            // Seeded from the model ids the Codex subscription currently exposes,
            // cheapest/fastest first. The user can add or remove any of these.
            ModelCatalog(builtIn: [
                "gpt-5.3-codex-spark",
                "gpt-5.6-luna",
                "gpt-5.6-terra",
                "gpt-5.5",
                "gpt-5.6-sol",
                "gpt-6-astra"
            ])
        case .anthropic, .gemini:
            ModelCatalog(builtIn: [])
        }
    }
}
