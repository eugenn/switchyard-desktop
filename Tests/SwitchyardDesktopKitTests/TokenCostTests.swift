import Foundation
import Testing
@testable import SwitchyardDesktopKit

/// Entries copied from LiteLLM's upstream map (trimmed to their cost keys),
/// plus the shapes the parser has to skip or expand.
private let priceJSON = """
{
  "sample_spec": {"input_cost_per_token": 0.0, "output_cost_per_token": 0.0},
  "fallback_generalizations": {"rules": []},
  "gpt-6-astra": {
    "input_cost_per_token": 1e-05, "output_cost_per_token": 5e-05,
    "cache_read_input_token_cost": 1e-06, "cache_creation_input_token_cost": 1.25e-05,
    "input_cost_per_token_above_272k_tokens": 2e-05, "output_cost_per_token_above_272k_tokens": 7.5e-05,
    "cache_read_input_token_cost_above_272k_tokens": 2e-06,
    "input_cost_per_token_above_272k_tokens_priority": 4e-05,
    "input_cost_per_token_above_272k_tokens_batches": 1e-05,
    "litellm_provider": "openai"
  },
  "gpt-5.5": {"input_cost_per_token": 5e-06, "output_cost_per_token": 3e-05, "cache_read_input_token_cost": 5e-07,
              "aliases": ["gpt-5.5-latest", "gpt-6-astra"]},
  "Reasoner": {"input_cost_per_token": "1e-06", "output_cost_per_token": 4e-06,
               "output_cost_per_reasoning_token": 2e-06},
  "chatgpt/gpt-5.3-codex-spark": {"litellm_provider": "chatgpt", "max_tokens": 128000},
  "openai/only-prefixed": {"input_cost_per_token": 1e-06, "output_cost_per_token": 2e-06}
}
"""

private func table() throws -> ModelPriceTable {
    try #require(ModelPriceTable(liteLLMJSON: Data(priceJSON.utf8)))
}

private func tokens(
    prompt: Int, cached: Int = 0, written: Int = 0, completion: Int, reasoning: Int = 0
) -> RoutingLogRecord.Tokens {
    RoutingLogRecord.Tokens(
        prompt: prompt, cached: cached, cacheCreation: written, completion: completion,
        reasoning: reasoning, total: prompt + completion
    )
}

private func costRecord(_ json: String, id: Int = 0) throws -> RoutingLogRecord {
    try #require(RoutingLogReader.record(from: json, id: id))
}

@Test func priceTableLoadsTheMapTheWayLiteLLMDoes() throws {
    let table = try table()
    // Reserved keys are not models.
    #expect(table.modelCount == 5)
    #expect(table.price(for: "sample_spec") == nil)
    // An alias gets its entry's price, but never replaces a real entry.
    #expect(table.price(for: "gpt-5.5-latest") == table.price(for: "gpt-5.5"))
    #expect(table.price(for: "gpt-6-astra")?.costs["input_cost_per_token"] == 1e-05)
    // Ids match case-insensitively, a provider prefix is optional, and a
    // price written as text still counts.
    #expect(table.price(for: "reasoner")?.costs["input_cost_per_token"] == 1e-06)
    #expect(table.price(for: "openai/GPT-5.5") == table.price(for: "gpt-5.5"))
    #expect(table.price(for: "only-prefixed") != nil)
    // A subscription entry with no per-token price is unpriced, not free.
    #expect(table.price(for: "gpt-5.3-codex-spark") == nil)
    #expect(ModelPriceTable(liteLLMJSON: Data("not json".utf8)) == nil)
}

/// Expected values are what `litellm.cost_per_token` returns for the same
/// usage and entry in the pinned LiteLLM 1.97.0.
@Test func costMatchesLiteLLMForCacheHitsReasoningAndTheLongPromptTier() throws {
    let table = try table()
    let astra = try #require(table.price(for: "gpt-6-astra"))
    let gpt55 = try #require(table.price(for: "gpt-5.5"))

    let recorded = tokens(prompt: 68_511, cached: 67_968, completion: 3_104, reasoning: 516)
    #expect(abs(TokenCostEstimate.cost(of: recorded, at: astra) - 0.228598) < 1e-9)
    // Above 272K prompt tokens every token type moves to that tier's rate.
    let long = tokens(prompt: 300_000, cached: 250_000, completion: 1_000, reasoning: 200)
    #expect(abs(TokenCostEstimate.cost(of: long, at: astra) - 1.575) < 1e-9)
    #expect(abs(TokenCostEstimate.cost(of: tokens(prompt: 1_000, cached: 800, completion: 100), at: gpt55) - 0.0044) < 1e-9)

    // Cache writes take their own rate; the tier only starts past its threshold.
    let written = tokens(prompt: 272_000, cached: 0, written: 2_000, completion: 0)
    #expect(abs(TokenCostEstimate.cost(of: written, at: astra) - (270_000 * 1e-05 + 2_000 * 1.25e-05)) < 1e-9)

    // A reasoning rate applies to the reasoning share of the completion only.
    let reasoner = try #require(table.price(for: "Reasoner"))
    let thought = tokens(prompt: 100, completion: 50, reasoning: 30)
    #expect(abs(TokenCostEstimate.cost(of: thought, at: reasoner) - (100 * 1e-06 + 20 * 4e-06 + 30 * 2e-06)) < 1e-12)

    // A missing cache rate is zero, as LiteLLM counts it, and a cached count
    // larger than the prompt is never priced twice.
    let plain = ModelPrice(input: 1e-06, output: 2e-06)
    #expect(abs(TokenCostEstimate.cost(of: tokens(prompt: 100, cached: 500, completion: 0), at: plain)) < 1e-12)
}

@Test func estimateNamesUnpricedModelsAndPricesAliasesAsTheirModel() throws {
    let table = try table()
    let records = try [
        costRecord(#"{"model":"gpt-5.5","prompt_tokens":1000,"cached_tokens":800,"completion_tokens":100}"#),
        costRecord(#"{"model":"judge-alias","tier":"classifier","prompt_tokens":1000,"completion_tokens":0}"#, id: 1),
        costRecord(#"{"model":"gpt-5.3-codex-spark","prompt_tokens":5000,"completion_tokens":100}"#, id: 2),
        costRecord(#"{"model":"mystery","prompt_tokens":10,"completion_tokens":0}"#, id: 3),
    ]
    let estimate = TokenCostEstimate.estimate(
        records: records, prices: table, aliases: ["judge-alias": "gpt-5.5"]
    )
    let judge = 1_000 * 5e-06
    #expect(abs(estimate.dollars - (0.0044 + judge)) < 1e-12)
    #expect(abs(estimate.uncachedDollars - (1_000 * 5e-06 + 100 * 3e-05 + judge)) < 1e-12)
    #expect(estimate.pricedCalls == 2)
    #expect(estimate.unpricedCalls == 2)
    #expect(estimate.unpricedTokens == 5_110)
    #expect(estimate.unpricedModels == ["gpt-5.3-codex-spark", "mystery"])
    #expect(TokenCostEstimate.estimate(records: [], prices: table).isEmpty)
}

/// A map large enough to pass LiteLLM's minimum-size check.
private func mapJSON(models: Int, extra: String = "") -> String {
    let entries = (0..<models).map { #""m\#($0)": {"input_cost_per_token": 1e-06, "output_cost_per_token": 2e-06}"# }
    return "{" + (entries + (extra.isEmpty ? [] : [extra])).joined(separator: ",") + "}"
}

@Test func readerPrefersAValidDownloadAndRejectsAShrunkenOne() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bundled = directory.appendingPathComponent("backup.json")
    let remote = directory.appendingPathComponent("remote.json")
    let cache = directory.appendingPathComponent("support/model-prices.json")
    try mapJSON(models: 100).write(to: bundled, atomically: true, encoding: .utf8)

    let offline = ModelPriceReader(bundledURL: bundled, cacheURL: cache, remoteURL: nil)
    #expect(offline.localPrices().source == .bundled)
    #expect(offline.needsDownload() == false)
    #expect(await offline.downloadPrices() == nil)

    // Under half of the bundled models: LiteLLM treats that as a broken file.
    try mapJSON(models: 49).write(to: remote, atomically: true, encoding: .utf8)
    let reader = ModelPriceReader(bundledURL: bundled, cacheURL: cache, remoteURL: remote)
    #expect(reader.needsDownload())
    #expect(await reader.downloadPrices() == nil)
    #expect(!FileManager.default.fileExists(atPath: cache.path))

    let newModel = #""gpt-new": {"input_cost_per_token": 3e-06, "output_cost_per_token": 6e-06}"#
    try mapJSON(models: 100, extra: newModel).write(to: remote, atomically: true, encoding: .utf8)
    let downloaded = try #require(await reader.downloadPrices())
    #expect(downloaded.price(for: "gpt-new") != nil)
    guard case .downloaded = downloaded.source else { Issue.record("not a download"); return }
    // Kept for the next launch, and fresh enough not to fetch again today.
    #expect(reader.localPrices().price(for: "gpt-new") != nil)
    #expect(!reader.needsDownload())
    #expect(reader.needsDownload(now: Date().addingTimeInterval(2 * 24 * 60 * 60)))
}

@Test func defaultReaderNeverReachesTheNetworkOrTheUsersDataUnderTest() {
    let reader = ModelPriceReader()
    #expect(reader.remoteURL == nil)
    #expect(reader.cacheURL?.path.hasPrefix(UserDataLocations.testSandbox.path) == true)
}

@MainActor
@Test func monitorCostFollowsTheFlowMapsSession() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("routing.jsonl")
    let prices = directory.appendingPathComponent("prices.json")
    try priceJSON.write(to: prices, atomically: true, encoding: .utf8)
    let now = Date().timeIntervalSince1970
    try """
    {"ts":\(now - 600),"session_id":"old","model":"gpt-5.5","prompt_tokens":1000,"completion_tokens":0}
    {"ts":\(now - 30),"session_id":"new","model":"gpt-5.5","prompt_tokens":0,"completion_tokens":1000}
    {"ts":\(now - 20),"session_id":"new","model":"gpt-5.3-codex-spark","prompt_tokens":50,"completion_tokens":0}
    """.write(to: log, atomically: true, encoding: .utf8)
    let model = WizardModel(
        sessionStore: ActiveRoutingSessionStore(fileURL: directory.appendingPathComponent("session.json")),
        restoreSavedSetup: false
    )
    let monitor = RoutingMonitor(
        model: model, logReader: RoutingLogReader(url: log),
        priceReader: ModelPriceReader(bundledURL: prices, cacheURL: nil, remoteURL: nil)
    )
    #expect(monitor.sessionCost.pricedCalls == 0)
    await monitor.refresh()

    #expect(monitor.activeSessionIDs == ["old", "new"])
    #expect(monitor.flowSession?.id == "new")
    #expect(abs(monitor.sessionCost.dollars - 1_000 * 3e-05) < 1e-12)
    #expect(monitor.sessionCost.unpricedModels == ["gpt-5.3-codex-spark"])

    monitor.selectedSessionID = "old"
    #expect(abs(monitor.sessionCost.dollars - 1_000 * 5e-06) < 1e-12)
    #expect(monitor.sessionCost.unpricedModels.isEmpty)
}
