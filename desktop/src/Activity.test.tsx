import { cleanup, render, screen, waitFor, within } from "@testing-library/react";
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
});
