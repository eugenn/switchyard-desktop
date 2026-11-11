import { useEffect, useRef, useState } from "react";
import { api, native, type ClaudeSettings } from "./api";
import { ModelPicker } from "./ModelPicker";

const empty: ClaudeSettings = { efficientModel: "", capableModel: "" };
const modelPattern = /^claude-[A-Za-z0-9._-]{1,193}$/;

function settingsProblem(settings: ClaudeSettings): string | null {
  const { efficientModel, capableModel } = settings;
  if (!efficientModel && !capableModel) return null;
  if (!efficientModel || !capableModel) return "Enter both Claude model IDs, or clear both to turn Claude Code routing off.";
  if (!modelPattern.test(efficientModel) || !modelPattern.test(capableModel)) return "Model IDs start with claude- and use only letters, numbers, dots, dashes and underscores.";
  return null;
}

export function ClaudeIntegration() {
  const [open, setOpen] = useState(false);
  const [settings, setSettings] = useState<ClaudeSettings>(empty);
  const [saved, setSaved] = useState<ClaudeSettings>(empty);
  const [keySaved, setKeySaved] = useState(false);
  const [key, setKey] = useState("");
  const [command, setCommand] = useState("");
  const [busy, setBusy] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const operation = useRef(false);
  const problem = settingsProblem(settings);
  const enabled = !!saved.efficientModel && !!saved.capableModel;
  const ready = enabled && keySaved;

  // Restore the saved setup and whether a key is already in the vault. The key itself
  // never reaches the page: only whether one exists.
  useEffect(() => {
    if (!native) return;
    let active = true;
    Promise.all([api.claudeSettings(), api.anthropicKeyStatus()]).then(([stored, hasKey]) => {
      if (!active) return;
      setSettings(stored); setSaved(stored); setKeySaved(hasKey); setLoaded(true);
      if (stored.efficientModel && stored.capableModel) api.claudeLaunchCommand(stored).then((text) => { if (active) setCommand(text); }, () => undefined);
    }).catch((reason: unknown) => { if (active) setError(String(reason)); });
    return () => { active = false; };
  }, []);

  async function perform(action: () => Promise<void>) {
    if (operation.current) return;
    operation.current = true; setBusy(true); setError(""); setMessage("");
    try { await action(); } catch (reason) { setError(String(reason)); }
    finally { operation.current = false; setBusy(false); }
  }
  function change(update: Partial<ClaudeSettings>) { setSettings((old) => ({ ...old, ...update })); setCommand(""); setMessage(""); }
  const saveKey = (value: string) => perform(async () => {
    await api.saveAnthropicKey(value);
    setKey(""); setKeySaved(!!value);
    setMessage(value ? "Key saved in the system credential vault." : "Key removed from the system credential vault.");
  });
  const saveSettings = () => perform(async () => {
    await api.saveClaudeSettings(settings);
    setSaved(settings);
    const on = !!settings.efficientModel && !!settings.capableModel;
    setCommand(on ? await api.claudeLaunchCommand(settings) : "");
    setMessage(on ? "Saved. The route is added the next time you start routing." : "Claude Code routing is off.");
  });
  const copy = () => perform(async () => { await navigator.clipboard.writeText(command); setMessage("Command copied."); });

  return <section className={`model-discovery claude-integration${open ? " open" : ""}`}>
    <div className="discovery-bar"><span className={`discovery-state${ready ? " ready" : ""}`}>{ready && <i aria-hidden="true" />}{ready ? "Claude Code route ready · Anthropic API key" : "Claude Code via Anthropic API key"}</span><button type="button" className="button secondary small" aria-expanded={open} onClick={() => setOpen(!open)}>{open ? "Close Claude setup" : "Set up Claude"}</button></div>
    {open && <div className="discovery-body">
      <p>Claude Code is sent through this app's local server, which calls Anthropic with your API key and picks between two Claude models. Requests appear in Activity. Usage is billed to your Anthropic API account, not to a Claude subscription. This is separate from the Codex route above.</p>
      <fieldset disabled={!native || !loaded || busy} className="credential-editor"><legend>Anthropic credential</legend>
        <p>Stored in macOS Keychain or Windows Credential Manager, not in setup files. Only the local server receives it; Claude Code never sees it.</p>
        <label>Anthropic API key<input type="password" autoComplete="off" value={key} onChange={(event) => setKey(event.target.value)} placeholder={keySaved ? "A key is saved" : "sk-ant-..."} /></label>
        <div className="role-toolbar"><button type="button" className="button secondary" disabled={!key.trim()} onClick={() => void saveKey(key)}>Save API key</button><button type="button" className="text-button" disabled={!keySaved} onClick={() => void saveKey("")}>Remove API key</button></div>
        <p role="status" className="quiet-note">{keySaved ? "An Anthropic key is saved in the system credential vault." : "No Anthropic key saved."}</p>
      </fieldset>
      <fieldset disabled={!native || !loaded || busy}><legend className="sr-only">Claude models</legend>
        <div className="discovery-row">
          <div className="discovery-field"><span>Efficient Claude model ID</span><ModelPicker provider="anthropic" label="Efficient Claude model ID" placeholder="claude-..." value={settings.efficientModel} onChange={(efficientModel) => change({ efficientModel })} /></div>
          <div className="discovery-field"><span>Capable Claude model ID</span><ModelPicker provider="anthropic" label="Capable Claude model ID" placeholder="claude-..." value={settings.capableModel} onChange={(capableModel) => change({ capableModel })} /></div>
        </div>
        <p className="quiet-note">Enter exact model IDs your Anthropic account can use. The app does not look them up. Routing uses the bundled Composite policy, not the Codex strategy editor. Clear both fields to turn the Claude Code route off.</p>
        <div className="discovery-row"><button type="button" className="button secondary" disabled={!!problem} onClick={() => void saveSettings()}>Save Claude setup</button></div>
      </fieldset>
      {problem && <p className="editor-warning" role="note">{problem}</p>}
      {enabled && !keySaved && <p className="editor-warning" role="note">Save your Anthropic API key before starting routing: the server needs it to call Claude.</p>}
      {command && <div className="credential-editor"><p>Start routing, then run this in your project directory. Switchyard serves Claude Code on this machine only; the key stays in the server.</p><code className="claude-command">{command}</code><button type="button" className="text-button" disabled={busy} onClick={() => void copy()}>Copy command</button></div>}
      {message && <p className="quiet-note" role="status">{message}</p>}
      {error && <p className="editor-warning" role="alert">{error}</p>}
    </div>}
  </section>;
}
