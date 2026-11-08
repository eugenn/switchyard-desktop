import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { api, type ClaudeStatus } from "./api";
import { ClaudeIntegration } from "./ClaudeIntegration";

vi.mock("./api", async () => {
  const actual = await vi.importActual<typeof import("./api")>("./api");
  return { ...actual, native: true, api: { ...actual.api, claudeSettings: vi.fn(), claudeStatus: vi.fn(), claudeLogin: vi.fn(), claudeCancelLogin: vi.fn(), prepareClaude: vi.fn() } };
});

const settings = { executable: "", efficientModel: "claude-test-small", capableModel: "claude-test-large" };
const connected: ClaudeStatus = { installed: true, version: "2.1.301", signedIn: true, subscriptionAuth: true, pending: false, supported: true, compatibleVersion: true, pluginAvailable: true, message: "Subscription connected through Claude Code", models: [] };

beforeEach(() => {
  vi.mocked(api.claudeSettings).mockResolvedValue(settings);
  vi.mocked(api.claudeStatus).mockResolvedValue(connected);
});
afterEach(() => { cleanup(); vi.resetAllMocks(); });

async function open() {
  render(<ClaudeIntegration />);
  fireEvent.click(screen.getByRole("button", { name: "Set up Claude" }));
  await screen.findByDisplayValue("claude-test-small");
}

it("recognizes an existing Claude sign-in at startup without signing in or preparing anything", async () => {
  render(<ClaudeIntegration />);
  await screen.findByText(/Claude subscription connected · 2.1.301/);
  expect(api.claudeSettings).toHaveBeenCalledTimes(1);
  expect(api.claudeStatus).toHaveBeenCalledWith(settings);
  expect(api.claudeLogin).not.toHaveBeenCalled();
  expect(api.prepareClaude).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Set up Claude" }));
  expect(screen.getByRole("button", { name: "Sign in again" })).toBeTruthy();
  expect(screen.queryByLabelText(/API key/)).toBeNull();
  expect(screen.getByRole("button", { name: "Prepare Claude routing" })).toHaveProperty("disabled", false);
});

it("stays quiet when the startup account check cannot run", async () => {
  vi.mocked(api.claudeStatus).mockRejectedValue("Could not launch bundled process: No such file or directory");
  await open();
  expect(screen.getByRole("button", { name: "Sign in with Claude Code" })).toBeTruthy();
  expect(screen.queryByRole("alert")).toBeNull();
  expect(screen.queryByText(/Claude subscription connected/)).toBeNull();
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
  vi.mocked(api.claudeStatus).mockResolvedValue({ ...connected, signedIn: false, subscriptionAuth: false, message: "Not signed in" });
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

it("shows a connected state when the browser sign-in finishes", async () => {
  vi.mocked(api.claudeLogin).mockResolvedValue({ ...connected, signedIn: false, subscriptionAuth: false, pending: true, message: "Waiting for browser" });
  vi.mocked(api.claudeStatus).mockResolvedValueOnce({ ...connected, signedIn: false, subscriptionAuth: false, pending: true, message: "Waiting for browser" }).mockResolvedValue(connected);
  await open();
  fireEvent.click(screen.getByRole("button", { name: "Sign in with Claude Code" }));
  await screen.findByText(/Waiting for browser/);
  await screen.findByText(/Claude subscription connected · 2.1.301/, {}, { timeout: 8000 });
  expect(screen.getByRole("button", { name: "Sign in again" })).toHaveProperty("disabled", false);
  expect(screen.queryByRole("button", { name: "Cancel Claude sign-in" })).toBeNull();
}, 15000);

it("explains why routing cannot be prepared for a connected but outdated Claude Code", async () => {
  vi.mocked(api.claudeSettings).mockResolvedValue({ ...settings, capableModel: "" });
  vi.mocked(api.claudeStatus).mockResolvedValue({ ...connected, version: "2.1.284 (Claude Code)", compatibleVersion: false, pluginAvailable: false });
  render(<ClaudeIntegration />);
  fireEvent.click(screen.getByRole("button", { name: "Set up Claude" }));
  await screen.findByDisplayValue("claude-test-small");
  fireEvent.click(screen.getByRole("button", { name: "Check Claude account" }));
  const note = await screen.findByRole("note");
  expect(note.textContent).toContain("Update Claude Code to 2.1.301 or newer (installed: 2.1.284 (Claude Code))");
  expect(note.textContent).toContain("Enter both Claude model IDs.");
  expect(note.textContent).not.toContain("bundled Claude plugin is missing");
  expect(screen.getByText(/Claude subscription connected · 2.1.284/)).toBeTruthy();
  fireEvent.change(screen.getByLabelText("Capable Claude model ID"), { target: { value: "claude-test-large" } });
  expect(screen.getByRole("note").textContent).not.toContain("Enter both Claude model IDs.");
});

it("lists the account's Claude models and fills either tier from them", async () => {
  vi.mocked(api.claudeSettings).mockResolvedValue({ executable: "", efficientModel: "", capableModel: "" });
  vi.mocked(api.claudeStatus).mockResolvedValue({ ...connected, models: [{ id: "claude-test-large", name: "Large", recommended: true }, { id: "claude-test-small", name: "Small", recommended: false }] });
  render(<ClaudeIntegration />);
  fireEvent.click(screen.getByRole("button", { name: "Set up Claude" }));
  fireEvent.click(await screen.findByRole("button", { name: "Check Claude account" }));
  await screen.findByText(/2 models available to your Claude account/);
  fireEvent.click(screen.getByRole("button", { name: "Use Small as efficient model" }));
  fireEvent.click(screen.getByRole("button", { name: "Use Large as capable model" }));
  expect(screen.getByLabelText("Efficient Claude model ID")).toHaveProperty("value", "claude-test-small");
  expect(screen.getByLabelText("Capable Claude model ID")).toHaveProperty("value", "claude-test-large");
  expect(screen.getByRole("button", { name: "Use Small as efficient model" }).getAttribute("aria-pressed")).toBe("true");
  expect(screen.getByRole("button", { name: "Prepare Claude routing" })).toHaveProperty("disabled", false);
});

it("does not show models before the subscription is confirmed", async () => {
  vi.mocked(api.claudeStatus).mockResolvedValue({ ...connected, subscriptionAuth: false, models: [{ id: "claude-test-large", name: "Large", recommended: true }] });
  await open();
  fireEvent.click(screen.getByRole("button", { name: "Check Claude account" }));
  await screen.findByText(/Subscription connected through Claude Code/);
  expect(screen.queryByText(/models available to your Claude account/)).toBeNull();
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
