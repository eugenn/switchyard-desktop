import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { App } from "./App";
import { api, type RouteSettings } from "./api";

vi.mock("./api", async (original) => {
  const module = await original<typeof import("./api")>();
  return { ...module, native: true, api: { bootstrap: vi.fn(), preview: vi.fn(), save: vi.fn(), saveLibrary: vi.fn(), typesafeKeyStatus: vi.fn(), saveTypesafeKey: vi.fn(), start: vi.fn(), stop: vi.fn(), status: vi.fn(), stats: vi.fn(), history: vi.fn(), modelPrices: vi.fn(), discoverModels: vi.fn(), importSetup: vi.fn(), beginLogin: vi.fn(), loginStatus: vi.fn(), cancelLogin: vi.fn(), claudeSettings: vi.fn(), claudeStatus: vi.fn() } };
});

const settings: RouteSettings = { algorithm: "stage_router", efficientModel: "test-small", capableModel: "test-large" };
const stoppedSession = { running: false, endpoint: "http://127.0.0.1:4100/v1", message: "Stopped" };
const login = { pending: false, signedIn: true, code: null, verificationUrl: null, message: "" };
const runtime = { available: true, platform: "test / isolated", missing: [] };

beforeEach(() => {
  vi.mocked(api.bootstrap).mockResolvedValue({ settings: { ...settings }, runtime, login, session: stoppedSession });
  vi.mocked(api.status).mockResolvedValue({ ...stoppedSession, running: true });
  vi.mocked(api.history).mockResolvedValue([]);
  vi.mocked(api.modelPrices).mockResolvedValue({});
  vi.mocked(api.claudeSettings).mockResolvedValue({ executable: "", efficientModel: "", capableModel: "" });
  vi.mocked(api.claudeStatus).mockRejectedValue("Claude Code is not installed in this test");
  vi.mocked(api.stats).mockResolvedValue({ total_requests: 7, total_tokens: { total: 120 }, total_errors: 0 });
});
afterEach(() => { cleanup(); vi.clearAllMocks(); });

const openPage = (name: "Routing" | "Roles" | "Activity" | "Requests") => fireEvent.click(screen.getByRole("button", { name: new RegExp(name) }));
const openStrategies = () => fireEvent.click(screen.getByRole("button", { name: "Change strategy" }));

it("loads saved settings without writing anything", async () => {
  render(<App />);
  await screen.findByDisplayValue("test-small");
  expect(api.save).not.toHaveBeenCalled();
  expect(api.start).not.toHaveBeenCalled();
});

it("preserves edited input after a failed save", async () => {
  vi.mocked(api.save).mockRejectedValue("Disk is read-only");
  render(<App />);
  const input = await screen.findByDisplayValue("test-small");
  fireEvent.change(input, { target: { value: "edited-model" } });
  fireEvent.click(screen.getByRole("button", { name: "Save settings" }));
  expect(await screen.findByRole("alert")).toHaveProperty("textContent", expect.stringContaining("Disk is read-only"));
  expect(screen.getByDisplayValue("edited-model")).toBeTruthy();
});

it("reads saved settings back and does not claim success before persistence", async () => {
  vi.mocked(api.save).mockResolvedValue();
  render(<App />);
  await screen.findByDisplayValue("test-small");
  fireEvent.click(screen.getByRole("button", { name: "Save settings" }));
  await screen.findByText(/Routing settings saved and read back/);
  expect(api.bootstrap).toHaveBeenCalledTimes(2);
});

it("starts an actual backend operation and stops through the backend", async () => {
  vi.mocked(api.start).mockResolvedValue({ ...stoppedSession, running: true });
  vi.mocked(api.stop).mockResolvedValue(stoppedSession);
  render(<App />);
  await screen.findByDisplayValue("test-small");
  fireEvent.click(screen.getByRole("button", { name: /Start routing/ }));
  await screen.findByRole("heading", { name: "Where requests go" });
  expect(api.start).toHaveBeenCalledWith(settings);
  await screen.findByText("7");
  fireEvent.click(screen.getByRole("button", { name: /Stop routing/ }));
  await waitFor(() => expect(api.stop).toHaveBeenCalledTimes(1));
  await screen.findByText(/Routing is off/);
});

it("disables start when the bundled runtime is missing", async () => {
  vi.mocked(api.bootstrap).mockResolvedValue({ settings, runtime: { ...runtime, available: false, missing: ["Python"] }, login, session: stoppedSession });
  render(<App />);
  await screen.findByText("Runtime not prepared");
  expect(screen.getByRole("button", { name: /Start routing/ })).toHaveProperty("disabled", true);
});

it("does not replace corrupt settings with defaults or allow writes", async () => {
  vi.mocked(api.bootstrap).mockRejectedValue("Could not read saved routing settings");
  render(<App />);
  await screen.findByRole("alert");
  expect(screen.getByRole("button", { name: "Save settings" })).toHaveProperty("disabled", true);
  expect(api.save).not.toHaveBeenCalled();
});

describe("model validation", () => {
  it("allows the same model in two roles and a single passthrough model", async () => {
    render(<App />);
    await screen.findByDisplayValue("test-small");
    fireEvent.change(screen.getByDisplayValue("test-large"), { target: { value: "test-small" } });
    expect(screen.getByRole("button", { name: /Start routing/ })).toHaveProperty("disabled", false);
    openStrategies();
    fireEvent.click(screen.getByRole("radio", { name: /Passthrough/ }));
    expect(screen.getByRole("button", { name: /Start routing/ })).toHaveProperty("disabled", false);
  });
});

it("does not offer Start until ChatGPT sign-in is complete", async () => {
  vi.mocked(api.bootstrap).mockResolvedValue({ settings, runtime, login: { ...login, signedIn: false }, session: stoppedSession });
  vi.mocked(api.beginLogin).mockResolvedValue({ ...login, signedIn: false, pending: true, code: "ABCD-1234", verificationUrl: "https://auth.openai.com/codex/device" });
  vi.mocked(api.cancelLogin).mockResolvedValue({ ...login, signedIn: false, message: "Cancelled" });
  render(<App />);
  await screen.findByDisplayValue("test-small");
  expect(screen.getByRole("button", { name: /Start routing/ })).toHaveProperty("disabled", true);
  fireEvent.click(screen.getByRole("button", { name: "Sign in with ChatGPT" }));
  await screen.findByText("ABCD-1234");
  expect(screen.getByRole("button", { name: /Start routing/ })).toHaveProperty("disabled", true);
  fireEvent.click(screen.getByRole("button", { name: "Cancel sign-in" }));
  await screen.findByRole("button", { name: "Sign in with ChatGPT" });
  expect(api.cancelLogin).toHaveBeenCalledTimes(1);
});

it("offers the complete algorithm catalog and edits custom roles and targets", async () => {
  render(<App />);
  await screen.findByDisplayValue("test-small");
  openStrategies();
  expect(screen.getByRole("radio", { name: /Custom classifier/ })).toBeTruthy();
  expect(screen.getByRole("radio", { name: /Verification-gated routing/ })).toBeTruthy();
  fireEvent.click(screen.getByRole("radio", { name: /Custom classifier/ }));
  fireEvent.change(screen.getByLabelText("Judge model"), { target: { value: "judge-model" } });
  fireEvent.change(screen.getByLabelText("Target 1 role"), { target: { value: "0D000000-0000-0000-0000-000000000001" } });
  expect(screen.getByText(/One named file or function/)).toBeTruthy();
  fireEvent.change(screen.getByLabelText("Target 2 role"), { target: { value: "0D000000-0000-0000-0000-000000000002" } });
  fireEvent.click(screen.getByRole("button", { name: "Add routing target" }));
  fireEvent.change(screen.getByLabelText("Target 3 model"), { target: { value: "third-model" } });
  fireEvent.change(screen.getByLabelText("Target 3 role"), { target: { value: "0D000000-0000-0000-0000-000000000003" } });
  fireEvent.click(screen.getByRole("button", { name: "Save settings" }));
  await waitFor(() => expect(api.save).toHaveBeenCalledWith(expect.objectContaining({ algorithm: "llm_classifier", judgeModel: "judge-model", targets: expect.arrayContaining([expect.objectContaining({ model: "third-model" })]) })));
});

it("selects a valid composite trigger and edits the shared role library", async () => {
  render(<App />);
  await screen.findByDisplayValue("test-small");
  openStrategies();
  fireEvent.click(screen.getByRole("radio", { name: /Composite/ }));
  expect(screen.getByLabelText("Classification trigger")).toHaveProperty("value", "user_turn");
  openPage("Roles");
  fireEvent.click(screen.getByRole("button", { name: "New role" }));
  fireEvent.change(screen.getByLabelText("Role name"), { target: { value: "My reviewer" } });
  expect(screen.getByRole("button", { name: /My reviewer/ })).toBeTruthy();
});

it("starts no-op without a model or a signed-in account", async () => {
  vi.mocked(api.bootstrap).mockResolvedValue({ settings, runtime, login: { ...login, signedIn: false }, session: stoppedSession });
  render(<App />);
  await screen.findByDisplayValue("test-small");
  openStrategies();
  fireEvent.click(screen.getByRole("radio", { name: /No-op/ }));
  expect(screen.getByRole("button", { name: /Start routing/ })).toHaveProperty("disabled", false);
});

it("saves the edited setup before starting, so a started route is never lost", async () => {
  vi.mocked(api.save).mockResolvedValue();
  vi.mocked(api.start).mockResolvedValue({ ...stoppedSession, running: true });
  render(<App />);
  const input = await screen.findByDisplayValue("test-small");
  expect(screen.getByText(/Settings are saved/)).toBeTruthy();
  fireEvent.change(input, { target: { value: "edited-model" } });
  expect(screen.getByText(/unsaved changes; starting saves them/)).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Save and start" }));
  await waitFor(() => expect(api.start).toHaveBeenCalledTimes(1));
  const edited = { ...settings, efficientModel: "edited-model" };
  expect(api.save).toHaveBeenCalledWith(edited);
  expect(api.start).toHaveBeenCalledWith(edited);
  expect(vi.mocked(api.save).mock.invocationCallOrder[0]).toBeLessThan(vi.mocked(api.start).mock.invocationCallOrder[0]);
});

it("explains each model slot, points at the missing model and undoes a strategy switch", async () => {
  render(<App />);
  await screen.findByDisplayValue("test-small");
  expect(screen.getByRole("region", { name: "Efficient" }).textContent).toContain("Serves most turns");
  openStrategies();
  fireEvent.click(screen.getByRole("radio", { name: /^Capability/ }));
  expect(screen.getByRole("region", { name: "Judge" }).textContent).toContain("picks the model before it is served");
  expect(screen.getByText("Choose a judge model or an existing judge target.")).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Show" }));
  expect(document.activeElement).toBe(screen.getByLabelText("Judge model"));
  fireEvent.click(screen.getByRole("button", { name: "Undo" }));
  expect(screen.queryByRole("region", { name: "Judge" })).toBeNull();
  expect(screen.getByText("Stage router")).toBeTruthy();
  expect(screen.getByDisplayValue("test-large")).toBeTruthy();
});

it("shows history details without counting decision outcomes as calls", async () => {
  vi.mocked(api.history).mockResolvedValue([{ model: "history-model", tier: "classifier", total_tokens: 17, agent_id: "worker-7", unknown_field: "kept" }]);
  render(<App />);
  await screen.findByDisplayValue("test-small");
  openPage("Requests");
  const row = within(await screen.findByRole("listbox", { name: /Calls/ })).getByRole("option", { name: /history-model/ });
  fireEvent.click(row);
  expect(row.getAttribute("aria-selected")).toBe("true");
  expect(screen.getByText("Judge call")).toBeTruthy();
  fireEvent.click(screen.getByText("Full log record"));
  expect(screen.getByText("unknown_field")).toBeTruthy();
  expect(screen.getByText("kept")).toBeTruthy();
});

it("folds a judge call under the call it routed and filters by kind", async () => {
  vi.mocked(api.history).mockResolvedValue([
    { ts: "2026-11-07T13:17:51Z", session_id: "s1", turn_id: "t1", model: "served-model", target: "standard", prompt_tokens: 1000, cached_tokens: 900, completion_tokens: 20, total_tokens: 1020 },
    { ts: "2026-11-07T13:17:40Z", session_id: "s1", turn_id: "t1", model: "judge-model", tier: "classifier", total_tokens: 40 },
  ]);
  render(<App />);
  await screen.findByDisplayValue("test-small");
  openPage("Requests");
  await screen.findByText(/judge · judge-model/);
  expect(within(screen.getByRole("listbox", { name: /Calls/ })).getAllByRole("option")).toHaveLength(1);
  fireEvent.click(screen.getByRole("radio", { name: "Judge" }));
  expect(within(screen.getByRole("listbox", { name: /Calls/ })).getAllByRole("option")).toHaveLength(1);
  expect(within(screen.getByRole("listbox", { name: /Calls/ })).getByRole("option", { name: /judge-model/ })).toBeTruthy();
  fireEvent.change(screen.getByLabelText("Search requests"), { target: { value: "nothing-matches" } });
  fireEvent.click(screen.getByRole("button", { name: "Clear filters" }));
  expect(within(screen.getByRole("listbox", { name: /Calls/ })).getByRole("option", { name: /served-model/ })).toBeTruthy();
});

it("imports a validated draft without automatically writing or starting", async () => {
  vi.mocked(api.importSetup).mockResolvedValue({ ...settings, algorithm: "auto" });
  render(<App />);
  await screen.findByDisplayValue("test-small");
  openPage("Roles");
  fireEvent.click(screen.getByText("Import / export routing setup"));
  fireEvent.change(screen.getByLabelText("Setup JSON"), { target: { value: "selected exported setup" } });
  fireEvent.click(screen.getByRole("button", { name: "Import as draft" }));
  await screen.findByText(/Imported as an unsaved draft/);
  openPage("Routing");
  openStrategies();
  expect(screen.getByRole("radio", { name: /Auto.*Recommended/ })).toHaveProperty("checked", true);
  expect(api.save).not.toHaveBeenCalled();
  expect(api.start).not.toHaveBeenCalled();
});

it("discovers account models only on an explicit click", async () => {
  vi.mocked(api.discoverModels).mockResolvedValue([{ id: "discovered-model", displayName: "Discovered model", supportsImages: true, contextWindow: 128000, efforts: ["high"] }]);
  render(<App />);
  await screen.findByDisplayValue("test-small");
  expect(api.discoverModels).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Load account models" }));
  fireEvent.click(screen.getByRole("button", { name: "Discover models" }));
  await screen.findByText(/1 models reported/);
  expect(api.discoverModels).toHaveBeenCalledWith("");
  expect(api.start).not.toHaveBeenCalled();
});


it("saves the role library even when routing models are incomplete", async () => {
  vi.mocked(api.bootstrap).mockResolvedValue({ settings: { ...settings, efficientModel: "", capableModel: "" }, runtime, login, session: stoppedSession });
  vi.mocked(api.saveLibrary).mockResolvedValue();
  render(<App />);
  await screen.findByText("Enter a valid model ID for each target.");
  openPage("Roles");
  fireEvent.click(screen.getByRole("button", { name: "New role" }));
  fireEvent.change(screen.getByLabelText("Role name"), { target: { value: "Persisted reviewer" } });
  fireEvent.click(screen.getByRole("button", { name: "Save role library" }));
  await screen.findByText(/Role library saved/);
  expect(api.saveLibrary).toHaveBeenCalledWith(expect.arrayContaining([expect.objectContaining({ name: "Persisted reviewer" })]), []);
  expect(api.save).not.toHaveBeenCalled();
  expect(api.start).not.toHaveBeenCalled();
});

it("keeps library edits on save failure and clears only library dirty state on retry", async () => {
  vi.mocked(api.saveLibrary).mockRejectedValueOnce("Could not save library").mockResolvedValueOnce();
  render(<App />);
  const model = await screen.findByDisplayValue("test-small");
  fireEvent.change(model, { target: { value: "unsaved-model" } });
  openPage("Roles");
  fireEvent.click(screen.getByRole("button", { name: "New role" }));
  fireEvent.change(screen.getByLabelText("Role name"), { target: { value: "Retry reviewer" } });
  expect(screen.getByText("Unsaved library changes")).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Save role library" }));
  await screen.findByText("Could not save library");
  expect(screen.getByLabelText("Role name")).toHaveProperty("value", "Retry reviewer");
  expect(screen.getByText("Unsaved library changes")).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Save role library" }));
  await screen.findByText("Library up to date");
  openPage("Routing");
  expect(screen.getByDisplayValue("unsaved-model")).toBeTruthy();
  expect(screen.getByText(/You have unsaved changes; starting saves them/)).toBeTruthy();
  expect(api.save).not.toHaveBeenCalled();
});

it("reads the saved library back on a fresh app mount", async () => {
  let stored: RouteSettings = { ...settings };
  vi.mocked(api.bootstrap).mockImplementation(async () => ({ settings: stored, runtime, login, session: stoppedSession }));
  vi.mocked(api.saveLibrary).mockImplementation(async (roles, roleGroups) => { stored = { ...stored, roles, roleGroups }; });
  const app = render(<App />);
  await screen.findByDisplayValue("test-small");
  openPage("Roles");
  fireEvent.click(screen.getByRole("button", { name: "New role" }));
  fireEvent.change(screen.getByLabelText("Role name"), { target: { value: "Saved reviewer" } });
  fireEvent.click(screen.getByRole("button", { name: "Save role library" }));
  await screen.findByText(/Role library saved/);
  app.unmount();
  render(<App />);
  await screen.findByDisplayValue("test-small");
  openPage("Roles");
  fireEvent.click(screen.getByRole("button", { name: /^Saved reviewer/ }));
  expect(screen.getByLabelText("Role name")).toHaveProperty("value", "Saved reviewer");
  expect(screen.getByText("Library up to date")).toBeTruthy();
});

it("starts with a routed profile: the Codex profile is part of every start, with no opt-in", async () => {
  vi.mocked(api.start).mockResolvedValue({ ...stoppedSession, running: true });
  render(<App />);
  await screen.findByDisplayValue("test-small");
  expect(screen.queryByRole("checkbox", { name: /Manage Codex profile/ })).toBeNull();
  expect(screen.getByText("codex --profile switch")).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: /Start routing/ }));
  await waitFor(() => expect(api.start).toHaveBeenCalledWith(settings));
});

it("preserves edited routing inputs when an import fails", async () => {
  vi.mocked(api.importSetup).mockRejectedValue("Unsupported setup");
  render(<App />);
  const input = await screen.findByDisplayValue("test-small");
  fireEvent.change(input, { target: { value: "unsaved-model" } });
  openPage("Roles");
  fireEvent.click(screen.getByText("Import / export routing setup"));
  fireEvent.change(screen.getByLabelText("Setup JSON"), { target: { value: "bad data" } });
  fireEvent.click(screen.getByRole("button", { name: "Import as draft" }));
  await screen.findByText("Unsupported setup");
  openPage("Routing");
  expect(screen.getByDisplayValue("unsaved-model")).toBeTruthy();
  expect(api.save).not.toHaveBeenCalled();
});

it("stores the Jev key through the native vault, never in routing settings", async () => {
  vi.mocked(api.typesafeKeyStatus).mockResolvedValue(false);
  vi.mocked(api.saveTypesafeKey).mockResolvedValue();
  render(<App />);
  await screen.findByDisplayValue("test-small");
  openStrategies();
  fireEvent.click(screen.getByRole("radio", { name: /^Capability/ }));
  fireEvent.click(screen.getByRole("checkbox", { name: "Use Jev / TypeSafe instead of an LLM judge" }));
  const input = await screen.findByLabelText("TypeSafe API key");
  fireEvent.change(input, { target: { value: "mock-not-a-real-key" } });
  fireEvent.click(screen.getByRole("button", { name: "Save API key" }));
  await screen.findByText(/Key saved in the system credential vault/);
  expect(input).toHaveProperty("value", "");
  expect(api.saveTypesafeKey).toHaveBeenCalledWith("mock-not-a-real-key");
  fireEvent.click(screen.getByRole("button", { name: "Save settings" }));
  await waitFor(() => expect(api.save).toHaveBeenCalledWith(expect.objectContaining({ jevClassifier: { modelID: "jev-latest", cutoff: 0.6, instructions: "" } })));
  expect(JSON.stringify(vi.mocked(api.save).mock.calls)).not.toContain("mock-not-a-real-key");
});

it("stores and restores routing setups inside project groups", async () => {
  render(<App />);
  await screen.findByDisplayValue("test-small");
  openPage("Roles");
  fireEvent.click(screen.getByText("Project groups"));
  fireEvent.click(screen.getByRole("button", { name: "New group" }));
  fireEvent.click(screen.getByRole("button", { name: "Save current setup to Project 1" }));
  openPage("Routing");
  fireEvent.change(screen.getByDisplayValue("test-small"), { target: { value: "edited-model" } });
  openPage("Roles");
  fireEvent.click(screen.getByText("Project groups"));
  fireEvent.click(screen.getByRole("button", { name: "Load setup from Project 1" }));
  openPage("Routing");
  expect(screen.getByDisplayValue("test-small")).toBeTruthy();
  expect(api.start).not.toHaveBeenCalled();
});
