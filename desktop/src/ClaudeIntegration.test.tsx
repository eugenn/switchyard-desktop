import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { api } from "./api";
import { ClaudeIntegration } from "./ClaudeIntegration";

vi.mock("./api", async () => {
  const actual = await vi.importActual<typeof import("./api")>("./api");
  return { ...actual, native: true, api: { ...actual.api, claudeSettings: vi.fn(), saveClaudeSettings: vi.fn(), claudeLaunchCommand: vi.fn(), anthropicKeyStatus: vi.fn(), saveAnthropicKey: vi.fn() } };
});

const settings = { efficientModel: "claude-test-small", capableModel: "claude-test-large" };
const command = "ANTHROPIC_BASE_URL='http://127.0.0.1:4100' ANTHROPIC_MODEL='switchyard-claude' claude";

beforeEach(() => {
  vi.mocked(api.claudeSettings).mockResolvedValue(settings);
  vi.mocked(api.anthropicKeyStatus).mockResolvedValue(true);
  vi.mocked(api.claudeLaunchCommand).mockResolvedValue(command);
  vi.mocked(api.saveClaudeSettings).mockResolvedValue();
  vi.mocked(api.saveAnthropicKey).mockResolvedValue();
});
afterEach(() => { cleanup(); vi.resetAllMocks(); });

async function open() {
  render(<ClaudeIntegration />);
  fireEvent.click(screen.getByRole("button", { name: "Set up Claude" }));
  await screen.findByDisplayValue("claude-test-small");
}

it("offers only an API key: no Claude Code sign-in, executable path or plug-in", async () => {
  await open();
  expect(screen.getByLabelText("Anthropic API key")).toBeTruthy();
  for (const text of [/Sign in/i, /Check Claude account/i, /executable/i, /Prepare Claude routing/i, /subscription connected/i, /mods/i]) {
    expect(screen.queryByText(text)).toBeNull();
  }
  expect(screen.queryByRole("button", { name: /sign in/i })).toBeNull();
});

it("shows the route as ready only when both models and a key are saved, and shows the stored command", async () => {
  render(<ClaudeIntegration />);
  await screen.findByText("Claude Code route ready · Anthropic API key");
  fireEvent.click(screen.getByRole("button", { name: "Set up Claude" }));
  await screen.findByText(command);
  expect(api.claudeLaunchCommand).toHaveBeenCalledWith(settings);
});

it("saves the key to the vault, clears the field and never echoes it back", async () => {
  vi.mocked(api.anthropicKeyStatus).mockResolvedValue(false);
  await open();
  expect(screen.getByRole("status").textContent).toBe("No Anthropic key saved.");
  expect(screen.getByText(/Without an Anthropic API key the Claude Code route stays off/)).toBeTruthy();
  const input = screen.getByLabelText("Anthropic API key") as HTMLInputElement;
  expect(input.type).toBe("password");
  expect(screen.getByRole("button", { name: "Save API key" })).toHaveProperty("disabled", true);
  fireEvent.change(input, { target: { value: "sk-ant-test-not-a-real-key" } });
  fireEvent.click(screen.getByRole("button", { name: "Save API key" }));
  await waitFor(() => expect(api.saveAnthropicKey).toHaveBeenCalledWith("sk-ant-test-not-a-real-key"));
  await screen.findByText("An Anthropic key is saved in the system credential vault.");
  expect(input.value).toBe("");
  expect(document.body.textContent).not.toContain("sk-ant-test-not-a-real-key");
  expect(screen.queryByText(/Without an Anthropic API key the Claude Code route stays off/)).toBeNull();
});

it("removes the key from the vault", async () => {
  await open();
  fireEvent.click(screen.getByRole("button", { name: "Remove API key" }));
  await waitFor(() => expect(api.saveAnthropicKey).toHaveBeenCalledWith(""));
  await screen.findByText("No Anthropic key saved.");
});

it("saves the setup and shows the launch command only after a valid save", async () => {
  vi.mocked(api.claudeSettings).mockResolvedValue({ efficientModel: "", capableModel: "" });
  render(<ClaudeIntegration />);
  fireEvent.click(screen.getByRole("button", { name: "Set up Claude" }));
  await waitFor(() => expect(api.claudeSettings).toHaveBeenCalled());
  const efficient = await screen.findByLabelText("Efficient Claude model ID");
  const capable = screen.getByLabelText("Capable Claude model ID");
  fireEvent.change(efficient, { target: { value: "claude-test-small" } });
  expect(screen.getByRole("button", { name: "Save Claude setup" })).toHaveProperty("disabled", true);
  expect(screen.getByRole("note").textContent).toMatch(/Enter both Claude model IDs/);
  fireEvent.change(capable, { target: { value: "claude-test-large" } });
  fireEvent.click(screen.getByRole("button", { name: "Save Claude setup" }));
  await screen.findByText(command);
  expect(api.saveClaudeSettings).toHaveBeenCalledWith(settings);
  expect(api.claudeLaunchCommand).toHaveBeenCalledWith(settings);
});

it("rejects malformed model IDs before saving and hides a stale command when they change", async () => {
  await open();
  await screen.findByText(command);
  const efficient = screen.getByLabelText("Efficient Claude model ID");
  fireEvent.change(efficient, { target: { value: "gpt-5" } });
  expect(screen.queryByText(command)).toBeNull();
  expect(screen.getByRole("button", { name: "Save Claude setup" })).toHaveProperty("disabled", true);
  expect(screen.getByRole("note").textContent).toMatch(/start with claude-/);
  expect(api.saveClaudeSettings).not.toHaveBeenCalled();
});

it("turns the route off when both models are cleared", async () => {
  await open();
  fireEvent.change(screen.getByLabelText("Efficient Claude model ID"), { target: { value: "" } });
  fireEvent.change(screen.getByLabelText("Capable Claude model ID"), { target: { value: "" } });
  fireEvent.click(screen.getByRole("button", { name: "Save Claude setup" }));
  await screen.findByText("Claude Code routing is off.");
  expect(api.saveClaudeSettings).toHaveBeenCalledWith({ efficientModel: "", capableModel: "" });
  expect(screen.queryByText(command)).toBeNull();
});

it("reports a vault failure without losing the typed key", async () => {
  vi.mocked(api.saveAnthropicKey).mockRejectedValue("Keychain did not save the Anthropic key. Check access permissions.");
  await open();
  const input = screen.getByLabelText("Anthropic API key") as HTMLInputElement;
  fireEvent.change(input, { target: { value: "sk-ant-test-not-a-real-key" } });
  fireEvent.click(screen.getByRole("button", { name: "Save API key" }));
  await screen.findByRole("alert");
  expect(screen.getByRole("alert").textContent).toMatch(/Keychain did not save/);
  expect(input.value).toBe("sk-ant-test-not-a-real-key");
});
