import Foundation

/// One model's cost fields from LiteLLM's price map, under LiteLLM's own key
/// names (`input_cost_per_token`, `cache_read_input_token_cost_above_272k_tokens`,
/// ...), so the estimate can apply them exactly the way LiteLLM does.
package struct ModelPrice: Equatable, Sendable {
    package let costs: [String: Double]

    package init(costs: [String: Double]) {
        self.costs = costs
    }

    package init(input: Double, output: Double, cacheRead: Double? = nil, cacheCreation: Double? = nil) {
        var costs = ["input_cost_per_token": input, "output_cost_per_token": output]
        costs["cache_read_input_token_cost"] = cacheRead
        costs["cache_creation_input_token_cost"] = cacheCreation
        self.init(costs: costs)
    }

    /// An entry without both base prices, such as a `chatgpt/` subscription
    /// model, is not priced: LiteLLM would report it as free.
    package var isPriced: Bool {
        costs["input_cost_per_token"] != nil && costs["output_cost_per_token"] != nil
    }

    /// The per-token rates one call is charged at.
    package struct Rates: Equatable, Sendable {
        package var input: Double
        package var output: Double
        package var cacheRead: Double
        package var cacheCreation: Double
        package var reasoning: Double
    }

    /// LiteLLM's `_get_token_base_cost` at the standard service tier: a prompt
    /// above a `_above_<n>k_tokens` threshold moves every token type to that
    /// tier's rate where the map names one. A missing cache rate is zero, as
    /// LiteLLM counts it.
    package func rates(promptTokens: Int) -> Rates {
        var rates = Rates(
            input: costs["input_cost_per_token"] ?? 0,
            output: costs["output_cost_per_token"] ?? 0,
            cacheRead: costs["cache_read_input_token_cost"] ?? 0,
            cacheCreation: costs["cache_creation_input_token_cost"] ?? 0,
            reasoning: 0
        )
        let tiers = costs.keys.compactMap(Self.threshold(of:)).sorted { $0.tokens > $1.tokens }
        if let tier = tiers.first(where: { Double(promptTokens) > $0.tokens }) {
            let suffix = "_above_\(tier.label)_tokens"
            rates.input = costs["input_cost_per_token\(suffix)"] ?? rates.input
            rates.output = costs["output_cost_per_token\(suffix)"] ?? rates.output
            rates.cacheCreation = costs["cache_creation_input_token_cost\(suffix)"] ?? rates.cacheCreation
            rates.cacheRead = costs["cache_read_input_token_cost\(suffix)"] ?? rates.cacheRead
        }
        rates.reasoning = costs["output_cost_per_reasoning_token"] ?? rates.output
        return rates
    }

    /// `input_cost_per_token_above_272k_tokens` → 272 000. Service-tier and
    /// batch variants of the key are not thresholds of the standard tier.
    private static func threshold(of key: String) -> (label: String, tokens: Double)? {
        let prefix = "input_cost_per_token_above_", suffix = "_tokens"
        guard key.hasPrefix(prefix), key.hasSuffix(suffix) else { return nil }
        let label = String(key.dropFirst(prefix.count).dropLast(suffix.count))
        let isThousands = label.hasSuffix("k")
        guard let value = Double(isThousands ? String(label.dropLast()) : label) else { return nil }
        return (label, isThousands ? value * 1_000 : value)
    }
}

/// Model id to its price, read from LiteLLM's `model_prices_and_context_window`
/// map. A model the map has not priced is reported as unpriced, never guessed.
package struct ModelPriceTable: Equatable, Sendable {
    package enum Source: Equatable, Sendable {
        case none
        /// The backup copy inside the pinned LiteLLM package.
        case bundled
        /// LiteLLM's upstream map, as downloaded at that time.
        case downloaded(Date)
    }

    /// Keys LiteLLM reserves for itself; neither is a model.
    package static let reservedKeys: Set<String> = ["sample_spec", "fallback_generalizations"]

    /// Lower-cased model id to its price: LiteLLM matches ids case-insensitively.
    package private(set) var prices: [String: ModelPrice]
    package var source: Source

    /// Model entries the map held, priced or not, for LiteLLM's own integrity
    /// check against a shrunken download.
    package private(set) var modelCount: Int

    package static let empty = ModelPriceTable(prices: [:])

    package init(prices: [String: ModelPrice], source: Source = .none) {
        self.prices = Dictionary(prices.map { ($0.key.lowercased(), $0.value) }) { first, _ in first }
        self.source = source
        modelCount = prices.count
    }

    /// Parses the map the way LiteLLM loads it: reserved keys dropped, and
    /// each entry's `aliases` expanded into ids of their own unless a real
    /// entry already claims that id.
    package init?(liteLLMJSON data: Data, source: Source = .none) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var prices: [String: ModelPrice] = [:]
        var aliases: [(String, ModelPrice)] = []
        var count = 0
        for (id, value) in object where !Self.reservedKeys.contains(id) {
            guard let entry = value as? [String: Any] else { continue }
            count += 1
            var costs: [String: Double] = [:]
            for (key, field) in entry where key.contains("cost") {
                if let number = Self.number(field) { costs[key] = number }
            }
            let price = ModelPrice(costs: costs)
            prices[id.lowercased()] = price
            for alias in entry["aliases"] as? [String] ?? [] { aliases.append((alias.lowercased(), price)) }
        }
        for (alias, price) in aliases where prices[alias] == nil { prices[alias] = price }
        self.prices = prices
        self.source = source
        modelCount = count
    }

    /// The price for a model id as the log records it, tried in LiteLLM's
    /// order: the id itself, the id without its provider, then the id under
    /// the provider LiteLLM infers for a bare name.
    package func price(for model: String) -> ModelPrice? {
        let id = model.lowercased()
        var candidates = [id]
        if let slash = id.firstIndex(of: "/") { candidates.append(String(id[id.index(after: slash)...])) }
        candidates += ["openai", "anthropic", "gemini"].map { "\($0)/\(id)" }
        for candidate in candidates {
            if let price = prices[candidate], price.isPriced { return price }
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

/// What a set of logged calls would cost at API list prices. Codex on a
/// ChatGPT plan is not billed per token, so this is an estimate of the
/// equivalent spend, not a bill.
package struct TokenCostEstimate: Equatable, Sendable {
    package var dollars: Double = 0
    /// What the same calls would have cost with no cache hits at all.
    package var uncachedDollars: Double = 0
    package var pricedCalls = 0
    package var unpricedCalls = 0
    package var unpricedTokens = 0
    /// Models the price table does not know, most tokens first.
    package var unpricedModels: [String] = []

    package var isEmpty: Bool { pricedCalls == 0 && unpricedCalls == 0 }

    /// - Parameter aliases: LiteLLM names the app publishes for a model it
    ///   serves under another id, such as the judge's own name.
    package static func estimate(
        records: [RoutingLogRecord], prices: ModelPriceTable, aliases: [String: String] = [:]
    ) -> TokenCostEstimate {
        var estimate = TokenCostEstimate()
        var unpriced: [String: Int] = [:]
        for record in records {
            let model = record.modelIdentity
            guard let price = prices.price(for: aliases[model] ?? model) else {
                estimate.unpricedCalls += 1
                estimate.unpricedTokens += record.tokens.total
                unpriced[model, default: 0] += record.tokens.total
                continue
            }
            estimate.pricedCalls += 1
            estimate.dollars += cost(of: record.tokens, at: price)
            var uncached = record.tokens
            uncached.cached = 0
            uncached.cacheCreation = 0
            estimate.uncachedDollars += cost(of: uncached, at: price)
        }
        estimate.unpricedModels = unpriced.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map(\.key)
        return estimate
    }

    /// LiteLLM's `generic_cost_per_token` for a text call. The prompt count
    /// already includes its cache hits and writes, so each part is priced once;
    /// reasoning tokens are part of the completion count and take the
    /// reasoning rate where the map names one.
    package static func cost(of tokens: RoutingLogRecord.Tokens, at price: ModelPrice) -> Double {
        let prompt = max(tokens.prompt, 0)
        let rates = price.rates(promptTokens: prompt)
        let cached = min(max(tokens.cached, 0), prompt)
        let written = min(max(tokens.cacheCreation, 0), prompt - cached)
        let text = prompt - cached - written
        let completion = max(tokens.completion, 0)
        let reasoning = min(max(tokens.reasoning, 0), completion)
        return Double(text) * rates.input
            + Double(cached) * rates.cacheRead
            + Double(written) * rates.cacheCreation
            + Double(completion - reasoning) * rates.output
            + Double(reasoning) * rates.reasoning
    }
}
