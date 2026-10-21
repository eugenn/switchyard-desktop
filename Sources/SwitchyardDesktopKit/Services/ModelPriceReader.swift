import Foundation

/// Where the cost estimate's prices come from: LiteLLM's own price map.
///
/// LiteLLM refreshes that map from its repository at import unless
/// `LITELLM_LOCAL_MODEL_COST_MAP` is set, and the app sets it so the proxy
/// never reaches the network on start. The copy pinned inside the package
/// then lags behind new models, so the estimate refreshes the same file from
/// the same URL itself, at most once a day, checks it the way LiteLLM does,
/// and keeps it beside the app's other data. The bundled copy stays the
/// fallback; nothing about the user is sent with the request.
package struct ModelPriceReader: Sendable {
    package static let upstreamURL = URL(
        string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
    )!

    /// LiteLLM's `MODEL_COST_MAP_MIN_MODEL_COUNT` and `MODEL_COST_MAP_MAX_SHRINK_RATIO`.
    package static let minimumModelCount = 50
    package static let maximumShrinkRatio = 0.5

    package let bundledURL: URL?
    package let cacheURL: URL?
    package let remoteURL: URL?
    package let maximumAge: TimeInterval

    package init(
        bundledURL: URL? = Self.bundledTableURL,
        cacheURL: URL? = UserDataLocations.supportDirectory.appendingPathComponent("model-prices.json"),
        remoteURL: URL? = UserDataLocations.isUnderTest ? nil : Self.upstreamURL,
        maximumAge: TimeInterval = 24 * 60 * 60
    ) {
        self.bundledURL = bundledURL
        self.cacheURL = cacheURL
        self.remoteURL = remoteURL
        self.maximumAge = maximumAge
    }

    package static var bundledTableURL: URL? {
        AppRuntimeLocator.liteLLMURL()?.appendingPathComponent(
            "lib/python3.12/site-packages/litellm/model_prices_and_context_window_backup.json"
        )
    }

    /// The last download when there is a valid one, otherwise the bundled map.
    package func localPrices() -> ModelPriceTable {
        let bundled = bundledPrices()
        if let cached = cachedPrices(), isAcceptable(cached, against: bundled) { return cached }
        return bundled ?? .empty
    }

    /// Whether the cached download is missing or older than a day.
    package func needsDownload(now: Date = Date()) -> Bool {
        guard remoteURL != nil else { return false }
        guard let cacheURL,
              let modified = try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { return true }
        return now.timeIntervalSince(modified) > maximumAge
    }

    /// Downloads the upstream map and keeps it when it passes LiteLLM's
    /// integrity check. Nil when there is nothing newer to use.
    package func downloadPrices() async -> ModelPriceTable? {
        guard let remoteURL else { return nil }
        let request = URLRequest(url: remoteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        guard let (data, response) = try? await URLSession(configuration: .ephemeral).data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              var table = ModelPriceTable(liteLLMJSON: data),
              isAcceptable(table, against: bundledPrices()) else { return nil }
        let now = Date()
        table.source = .downloaded(now)
        if let cacheURL {
            try? FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        }
        return table
    }

    private func bundledPrices() -> ModelPriceTable? {
        guard let bundledURL, let data = try? Data(contentsOf: bundledURL) else { return nil }
        return ModelPriceTable(liteLLMJSON: data, source: .bundled)
    }

    private func cachedPrices() -> ModelPriceTable? {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL) else { return nil }
        let modified = (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        return ModelPriceTable(liteLLMJSON: data, source: .downloaded(modified))
    }

    /// LiteLLM rejects a fetched map that is nearly empty or lost more than
    /// half of the models its own backup has.
    private func isAcceptable(_ table: ModelPriceTable, against bundled: ModelPriceTable?) -> Bool {
        guard table.modelCount >= Self.minimumModelCount else { return false }
        guard let bundled, bundled.modelCount > 0 else { return true }
        return Double(table.modelCount) >= Double(bundled.modelCount) * Self.maximumShrinkRatio
    }
}
