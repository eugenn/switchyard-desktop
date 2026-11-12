import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Activity } from "./Activity";
import { api } from "./api";

vi.mock("./api", async (original) => {
  const module = await original<typeof import("./api")>();
  return { ...module, native: true, api: { ...module.api, history: vi.fn(), modelPrices: vi.fn(), rolloutSessionIDs: vi.fn(), claudeSettings: vi.fn() } };
});

afterEach(() => { cleanup(); vi.resetAllMocks(); });

describe("activity parity", () => {
  it("updates context meters when model metadata and later turns arrive with no explicit context setting", async () => {
    vi.mocked(api.history).mockResolvedValue([{ session_id: "real", model: "m", ts: 100, prompt_tokens: 64000 }]);
    let refresh!: (table: Record<string, Record<string, number>>) => void;
    vi.mocked(api.modelPrices).mockImplementation(async (remote) => remote
      ? new Promise((resolve) => { refresh = resolve; })
      : {});
    const props = { settings: { algorithm: "passthrough" as const, efficientModel: "m", capableModel: "" }, stats: null, statsError: "", running: false, onOpenRequests: () => {}, onConfigure: () => {} };
    const { rerender } = render(<Activity {...props} />);
    expect(await screen.findByText("64K / —")).toBeTruthy();
    await waitFor(() => expect(refresh).toBeTypeOf("function"));
    refresh({ m: { max_input_tokens: 128000 } });
    expect(await screen.findByText("64K / 128K")).toBeTruthy();
    expect(screen.getByText("50%")).toBeTruthy();
    vi.mocked(api.history).mockResolvedValue([{ session_id: "real", model: "m", ts: 200, prompt_tokens: 96000 }]);
    rerender(<Activity {...props} running />);
    expect(await screen.findByText("96K / 128K")).toBeTruthy();
    expect(screen.getByText("75%")).toBeTruthy();
  });

  it("refreshes prices and excludes naming threads before choosing a session and pricing its judge", async () => {
    vi.mocked(api.history).mockResolvedValue([
      { origin: "codex-cli", session_id: "naming", model: "gpt-6.1-sol", ts: 200, prompt_tokens: 50 },
      { origin: "codex-cli", session_id: "real", model: "gpt-6.1-sol", ts: 100, prompt_tokens: 1000 },
      { origin: "codex-cli", session_id: "real", model: "judge-gpt-6.1-sol", tier: "classifier", ts: 90, prompt_tokens: 1000 },
    ]);
    vi.mocked(api.rolloutSessionIDs).mockResolvedValue(["real"]);
    vi.mocked(api.modelPrices).mockImplementation(async (refresh): Promise<Record<string, Record<string, number>>> => refresh
      ? { "gpt-6.1-sol": { input_cost_per_token: 0.00001, output_cost_per_token: 0.00002 } }
      : {});
    render(<Activity settings={{ algorithm: "stage_router", efficientModel: "gpt-6.1-sol", capableModel: "gpt-6-astra", judgeModel: "gpt-6.1-sol" }} stats={null} statsError="" running={false} onOpenRequests={() => {}} onConfigure={() => {}} />);
    expect(await screen.findByText("$0.02")).toBeTruthy();
    expect(api.modelPrices).toHaveBeenCalledWith(true);
    expect(api.rolloutSessionIDs).toHaveBeenCalledWith(["naming", "real"]);
    const picker = screen.getByRole("combobox", { name: "Session" });
    expect(within(picker).getAllByRole("option")).toHaveLength(1);
    expect(picker).toHaveProperty("value", "real");
    expect(screen.queryByText(/no list price for/)).toBeNull();
  });

  it("keeps conversations visible when rollout inspection fails and prices from the local fallback", async () => {
    vi.mocked(api.history).mockResolvedValue([{ origin: "codex-cli", session_id: "real", model: "m", prompt_tokens: 1000 }]);
    vi.mocked(api.rolloutSessionIDs).mockRejectedValue("Unavailable");
    vi.mocked(api.modelPrices).mockImplementation(async (refresh) => {
      if (refresh) throw new Error("Offline");
      return { m: { input_cost_per_token: 0.00001, output_cost_per_token: 0.00002 } };
    });
    render(<Activity settings={{ algorithm: "passthrough", efficientModel: "m", capableModel: "" }} stats={null} statsError="" running={false} onOpenRequests={() => {}} onConfigure={() => {}} />);
    expect(await screen.findByText("$0.01")).toBeTruthy();
    await waitFor(() => expect(screen.getByRole("combobox", { name: "Session" })).toHaveProperty("value", "real"));
  });

  it("shows a Claude Code session on its own route instead of the Codex profile", async () => {
    vi.mocked(api.claudeSettings).mockResolvedValue({ efficientModel: "claude-sonnet-5-5", capableModel: "claude-opus-5-5" });
    vi.mocked(api.modelPrices).mockResolvedValue({});
    vi.mocked(api.history).mockResolvedValue([
      { route_id: "switchyard-claude", origin: "claude-code", session_id: "claude-session", model: "claude-sonnet-5-5", target: "claude_efficient", tier: "", ts: 200, prompt_tokens: 1000 },
      { route_id: "switchyard-claude", origin: "claude-code", session_id: "claude-session", model: "claude-sonnet-5-5", target: "claude_efficient", tier: "classifier", ts: 199, prompt_tokens: 100 },
    ]);
    const settings = { algorithm: "stage_router" as const, efficientModel: "gpt-codex-small", capableModel: "gpt-codex-big" };
    render(<Activity settings={settings} stats={null} statsError="" running={false} onOpenRequests={() => {}} onConfigure={() => {}} />);
    const map = await screen.findByRole("region", { name: "Where requests go" });
    expect(await within(map).findByText("claude-code")).toBeTruthy();
    expect(within(map).getByText("Capable")).toBeTruthy();
    expect(within(map).getByText("Efficient")).toBeTruthy();
    expect(within(map).queryByText(/gpt-codex/)).toBeNull();
    expect(within(map).queryByText("codex")).toBeNull();
  });

  it("keeps the error count's meaning when classifier calls fail or a route falls back", async () => {
    vi.mocked(api.history).mockResolvedValue([]);
    vi.mocked(api.modelPrices).mockResolvedValue({});
    const stats = { total_errors: 3, classifier: { total_requests: 26, total_errors: 4 }, routing_fallbacks: { "a→b": 2 } };
    render(<Activity settings={{ algorithm: "passthrough", efficientModel: "m", capableModel: "" }} stats={stats} statsError="" running onOpenRequests={() => {}} onConfigure={() => {}} />);
    const summary = await screen.findByRole("region", { name: "Summary" });
    const stat = within(summary).getByText("3").closest(".act-stat")!;
    expect(stat.textContent).toContain("model errors since start");
    expect(stat.textContent).toContain("4 classifier failed");
    expect(stat.getAttribute("title")).toContain("4 of 26 classifier calls failed.");
    expect(stat.getAttribute("title")).toContain("Fallback a→b: 2.");
  });

  it("ends an idle session's timeline at its last turn instead of now", async () => {
    const last = Date.now() - 2 * 3600_000;
    vi.mocked(api.history).mockResolvedValue([{ session_id: "old", model: "m", ts: last, prompt_tokens: 10 }, { session_id: "old", model: "m", ts: last - 60_000, prompt_tokens: 10 }]);
    vi.mocked(api.modelPrices).mockResolvedValue({});
    render(<Activity settings={{ algorithm: "passthrough", efficientModel: "m", capableModel: "" }} stats={null} statsError="" running onOpenRequests={() => {}} onConfigure={() => {}} />);
    const map = await screen.findByRole("region", { name: "Where requests go" });
    expect(await within(map).findByText(/idle 2 h/)).toBeTruthy();
    expect(within(map).queryByText("now")).toBeNull();
  });

  it("drops a model filter that the newly picked session has no lane for", async () => {
    const now = Date.now();
    vi.mocked(api.history).mockResolvedValue([
      { session_id: "a", model: "m", ts: now, prompt_tokens: 10 },
      { session_id: "b", model: "n", ts: now - 1000, prompt_tokens: 10 },
    ]);
    vi.mocked(api.modelPrices).mockResolvedValue({});
    const latency = { count: 1, p50_ms: 1000, p99_ms: 2000 };
    const stats = { models: { m: { calls: 1, total_latency: latency }, n: { calls: 1, total_latency: latency } } };
    render(<Activity settings={{ algorithm: "random", efficientModel: "m", capableModel: "n" }} stats={stats} statsError="" running onOpenRequests={() => {}} onConfigure={() => {}} />);
    fireEvent.click(await screen.findByRole("button", { name: /^[^,]+, m, / }));
    const card = screen.getByRole("region", { name: "Latency" });
    expect(within(card).getByText("m · p50 / p99, s")).toBeTruthy();
    fireEvent.change(screen.getByRole("combobox", { name: "Session" }), { target: { value: "b" } });
    expect(await within(card).findByText("p50 / p99, seconds")).toBeTruthy();
  });

  it("reports both failures and shows no counts it could not read", async () => {
    vi.mocked(api.history).mockRejectedValue("Permission denied");
    vi.mocked(api.modelPrices).mockResolvedValue({});
    render(<Activity settings={{ algorithm: "passthrough", efficientModel: "m", capableModel: "" }} stats={null} statsError="not ready" running onOpenRequests={() => {}} onConfigure={() => {}} />);
    const alert = await screen.findByRole("alert");
    await waitFor(() => expect(alert.textContent).toContain("Routing log unavailable: Permission denied"));
    expect(alert.textContent).toContain("Statistics unavailable: not ready");
    expect(screen.getByText("The routing log could not be read, so no turns are shown.")).toBeTruthy();
    const summary = screen.getByRole("region", { name: "Summary" });
    expect(within(summary).queryByText("0")).toBeNull();
  });
});
