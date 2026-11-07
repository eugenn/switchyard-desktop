import { cleanup, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Activity } from "./Activity";
import { api } from "./api";

vi.mock("./api", async (original) => {
  const module = await original<typeof import("./api")>();
  return { ...module, native: true, api: { ...module.api, history: vi.fn(), modelPrices: vi.fn(), rolloutSessionIDs: vi.fn() } };
});

afterEach(() => { cleanup(); vi.resetAllMocks(); });

describe("activity parity", () => {
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
});
