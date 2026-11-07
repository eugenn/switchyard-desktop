import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { api, type ClaudeStatus } from "./api";
import { ClaudeIntegration } from "./ClaudeIntegration";

vi.mock("./api", async () => {
  const actual = await vi.importActual<typeof import("./api")>("./api");
  return { ...actual, native: true, api: { ...actual.api, claudeSettings: vi.fn(), claudeStatus: vi.fn(), claudeLogin: vi.fn(), claudeCancelLogin: vi.fn(), prepareClaude: vi.fn() } };
});

const settings = { executable: "", efficientModel: "claude-test-small", capableModel: "claude-test-large" };
const connected: ClaudeStatus = { installed: true, version: "2.1.301", signedIn: true, subscriptionAuth: true, pending: false, supported: true, pluginAvailable: true, message: "Subscription connected through Claude Code" };

beforeEach(() => {
  vi.mocked(api.claudeSettings).mockResolvedValue(settings);
  vi.mocked(api.claudeStatus).mockResolvedValue(connected);
});
afterEach(() => { cleanup(); vi.resetAllMocks(); });

async function open() {
  render(<ClaudeIntegration />);
  expect(api.claudeSettings).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Set up Claude" }));
  await screen.findByDisplayValue("claude-test-small");
}

it("loads only settings on explicit open, not account credentials or model calls", async () => {
  await open();
  expect(api.claudeStatus).not.toHaveBeenCalled();
  expect(api.claudeLogin).not.toHaveBeenCalled();
  expect(api.prepareClaude).not.toHaveBeenCalled();
  expect(screen.queryByLabelText(/API key/)).toBeNull();
  expect(screen.getByRole("button", { name: "Prepare Claude routing" })).toHaveProperty("disabled", true);
});

it("prepares the native plugin only after an explicit subscription check", async () => {
  vi.mocked(api.prepareClaude).mockResolvedValue({ directory: "/tmp/plugin", command: "claude --plugin-dir '/tmp/plugin'" });
  await open();
  fireEvent.click(screen.getByRole("button", { name: "Check Claude account" }));
  await screen.findByText(/Subscription connected/);
  fireEvent.click(screen.getByRole("button", { name: "Prepare Claude routing" }));
  await screen.findByText("claude --plugin-dir '/tmp/plugin'");
  expect(api.prepareClaude).toHaveBeenCalledWith(settings);
  fireEvent.change(screen.getByLabelText("Claude Code executable (optional absolute path)"), { target: { value: "/tmp/another-claude" } });
  expect(screen.getByRole("button", { name: "Prepare Claude routing" })).toHaveProperty("disabled", true);
  expect(screen.queryByText("claude --plugin-dir '/tmp/plugin'")).toBeNull();
});

it("does not present API authentication or missing native support as subscription routing", async () => {
  vi.mocked(api.claudeStatus).mockResolvedValue({ ...connected, subscriptionAuth: false, message: "API authentication" });
  await open();
  fireEvent.click(screen.getByRole("button", { name: "Check Claude account" }));
  await screen.findByText(/API authentication/);
  expect(screen.getByRole("button", { name: "Prepare Claude routing" })).toHaveProperty("disabled", true);
  vi.mocked(api.claudeStatus).mockResolvedValue({ ...connected, pluginAvailable: false, supported: false, message: "Windows unavailable" });
  fireEvent.click(screen.getByRole("button", { name: "Check Claude account" }));
  await screen.findByText(/Windows unavailable/);
  expect(screen.getByRole("button", { name: "Prepare Claude routing" })).toHaveProperty("disabled", true);
});

it("cancels only the pending Claude login and preserves model inputs", async () => {
  vi.mocked(api.claudeLogin).mockResolvedValue({ ...connected, signedIn: false, subscriptionAuth: false, pending: true, message: "Waiting for browser" });
  vi.mocked(api.claudeCancelLogin).mockResolvedValue({ ...connected, signedIn: false, subscriptionAuth: false, message: "Cancelled without deleting credentials" });
  await open();
  fireEvent.click(screen.getByRole("button", { name: "Sign in with Claude Code" }));
  await screen.findByText(/Waiting for browser/);
  fireEvent.click(screen.getByRole("button", { name: "Cancel Claude sign-in" }));
  await screen.findByText(/Cancelled without deleting credentials/);
  expect(api.claudeCancelLogin).toHaveBeenCalledTimes(1);
  expect(screen.getByDisplayValue("claude-test-small")).toBeTruthy();
});

it("shows preparation failures without displaying a launch command", async () => {
  vi.mocked(api.prepareClaude).mockRejectedValue("Missing bundled native helper");
  await open();
  fireEvent.click(screen.getByRole("button", { name: "Check Claude account" }));
  await screen.findByText(/Subscription connected/);
  fireEvent.click(screen.getByRole("button", { name: "Prepare Claude routing" }));
  await waitFor(() => expect(screen.getByRole("alert").textContent).toContain("Missing bundled native helper"));
  expect(screen.queryByRole("button", { name: "Copy command" })).toBeNull();
});
