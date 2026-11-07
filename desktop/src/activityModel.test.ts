import { describe, expect, it } from "vitest";
import { callCost, computeMetrics, dollars, droppingHousekeepingThreads, durationText, estimateCost, priceFor, lanes, parseRecord, parseRecords, parseStats, profile, sessions, ticks } from "./activityModel";
import type { RouteSettings } from "./api";

const at = (minute: number) => new Date(Date.UTC(2026, 10, 7, 13, minute)).toISOString();

describe("routing log records", () => {
  it("reads nested and aliased usage fields from routing records", () => {
    const record = parseRecord({ ts: at(0), model: "m", sessionId: "abc", usage: { prompt_tokens: 100, completion_tokens: 20, prompt_tokens_details: { cached_tokens: 90 } } }, 0);
    expect(record.sessionID).toBe("abc");
    expect(record.tokens).toMatchObject({ prompt: 100, completion: 20, cached: 90, total: 120 });
    expect(record.contextInputTokens).toBe(100);
    expect(parseRecord({ tier: "Classifier" }, 1).isClassifier).toBe(true);
    expect(parseRecord({ ts: 1_700_000_000 }, 2).ts).toBe(1_700_000_000_000);
  });
});

describe("metrics", () => {
  it("excludes Codex naming threads but keeps rollouts, multi-turn, other-client and pending sessions", () => {
    const records = parseRecords([
      { origin: "codex-cli", session_id: "real" },
      { origin: "codex-cli", session_id: "multi" }, { origin: "codex-cli", session_id: "multi" },
      { origin: "codex-cli", session_id: "naming", tier: "classifier" }, { origin: "codex-cli", session_id: "naming" },
      { origin: "claude-code", session_id: "other" },
      { origin: "codex-cli", session_id: "pending", tier: "classifier" },
      { origin: "codex-cli" },
    ]);
    const kept = droppingHousekeepingThreads(records, new Set(["real"]));
    expect(kept).toHaveLength(6);
    expect(sessions(kept).map((session) => session.id).sort()).toEqual(["multi", "other", "pending", "real"]);
    expect(droppingHousekeepingThreads(records, new Set(["real", "naming"]))).toHaveLength(8);
  });
  const rows = [
    { ts: at(10), model: "big", tier: "capable", session_id: "s1", total_tokens: 400 },
    { ts: at(9), model: "small", tier: "efficient", session_id: "s1", total_tokens: 100 },
    { ts: at(8), model: "small", tier: "efficient", session_id: "s1", total_tokens: 100 },
    { ts: at(7), model: "judge", tier: "classifier", session_id: "s1", total_tokens: 10 },
    { ts: at(1), model: "small", tier: "efficient", session_id: "s1", total_tokens: 100 },
  ];
  const records = parseRecords(rows);
  const settings: RouteSettings = { algorithm: "stage_router", efficientModel: "small", capableModel: "big" };

  it("counts served turns only, keeps idle assignments and marks the newest call", () => {
    const [session] = sessions(records);
    expect(session).toMatchObject({ id: "s1", turns: 4, classifierCalls: 1, shortTitle: "Session s1" });
    const metrics = computeMetrics(records, Date.parse(at(11)), { start: session.startedAt!, end: session.lastActivity! }, new Map([["small", "Efficient"], ["big", "Capable"], ["idle", "Spare"]]));
    expect(metrics.count).toBe(4);
    expect(metrics.classifierCount).toBe(1);
    expect(metrics.shares.map((share) => [share.id, share.count, share.share])).toEqual([["small", 3, 0.75], ["big", 1, 0.25], ["idle", 0, 0]]);
    expect(metrics.latest).toMatchObject({ modelID: "big", isClassifier: false });
    expect(metrics.secondsPerRequest).toBe(135);
  });

  it("orders lanes by role effort and scales ticks against the heaviest turn", () => {
    const flow = profile({ ...settings, efficientRoleId: "0D000000-0000-0000-0000-000000000001", capableRoleId: null });
    const metrics = computeMetrics(records, Date.parse(at(11)), null, flow.assignments);
    expect(lanes(metrics, flow.roles)[0].id).toBe("small");
    const placed = ticks(records, "s1", Date.parse(at(0)), Date.parse(at(10)));
    expect(placed.get("big")).toEqual([{ position: 1, weight: 1 }]);
    expect(placed.get("small")![0]).toEqual({ position: 0.1, weight: 0.5 });
    expect(placed.has("judge")).toBe(false);
  });
});

describe("server stats and formatting", () => {
  it("parses latency only when the proxy measured it", () => {
    const stats = parseStats({ total_requests: "5", models: { a: { calls: 1, total_latency: { count: 1, p50_ms: 1200, p99_ms: 3000 } }, b: 4 }, routing_fallbacks: { z: 0, y: 2 } });
    expect(stats.totalRequests).toBe(5);
    expect(stats.models.map((model) => [model.id, model.requests, model.latency])).toEqual([["b", 4, null], ["a", 1, { p50: 1200, p99: 3000 }]]);
    expect(stats.fallbacks).toEqual([["y", 2]]);
    expect([durationText(24), durationText(1680), durationText(3725)]).toEqual(["24 s", "28 min", "1 h 2 min"]);
  });
});

describe("cost at API list prices", () => {
  const table = {
    "openai/gpt-x": { input_cost_per_token: 1e-6, output_cost_per_token: 4e-6, cache_read_input_token_cost: 1e-7, output_cost_per_reasoning_token: 8e-6,
      input_cost_per_token_above_272k_tokens: 2e-6, cache_read_input_token_cost_above_272k_tokens: 2e-7 },
    "half-priced": { input_cost_per_token: 1e-6 },
  };
  const tokens = (prompt: number, cached: number, completion: number, reasoning = 0) => ({ prompt, cached, cacheCreation: 0, completion, reasoning, total: prompt + completion });

  it("finds a bare model under its inferred provider and never prices a half entry", () => {
    expect(priceFor("GPT-X", table)).toBe(table["openai/gpt-x"]);
    expect(priceFor("half-priced", table)).toBeNull();
  });

  it("prices cache hits, reasoning and the long-context tier like LiteLLM", () => {
    expect(callCost(tokens(1000, 900, 100, 40), table["openai/gpt-x"])).toBeCloseTo(100 * 1e-6 + 900 * 1e-7 + 60 * 4e-6 + 40 * 8e-6, 12);
    expect(callCost(tokens(300_000, 0, 0), table["openai/gpt-x"])).toBeCloseTo(300_000 * 2e-6, 12);
  });

  it("names unpriced models instead of guessing", () => {
    const records = parseRecords([{ model: "gpt-x", prompt_tokens: 1000, completion_tokens: 0 }, { model: "mystery", total_tokens: 50 }, { model: "mystery", total_tokens: 70 }]);
    const estimate = estimateCost(records, table);
    expect(estimate).toMatchObject({ pricedCalls: 1, unpricedCalls: 2, unpricedTokens: 120, unpricedModels: ["mystery"] });
    expect([dollars(estimate.dollars), dollars(0.004), dollars(2.554)]).toEqual(["<$0.01", "<$0.01", "$2.55"]);
  });

  it("prices the configured judge alias without guessing prices for unknown models", () => {
    const records = parseRecords([{ model: "judge-gpt-x", tier: "classifier", prompt_tokens: 1000 }]);
    expect(estimateCost(records, table, { "judge-gpt-x": "gpt-x" })).toMatchObject({ pricedCalls: 1, unpricedCalls: 0, dollars: 0.001 });
    expect(estimateCost(records, table).unpricedModels).toEqual(["judge-gpt-x"]);
  });
});
