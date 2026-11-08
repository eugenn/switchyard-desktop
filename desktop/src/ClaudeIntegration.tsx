import { useEffect, useRef, useState } from "react";
import { api, native, type ClaudeSettings, type ClaudeStatus, type PreparedClaudePlugin } from "./api";

const empty: ClaudeSettings = { executable: "", efficientModel: "", capableModel: "" };

export function ClaudeIntegration() {
  const [open, setOpen] = useState(false);
  const [settings, setSettings] = useState<ClaudeSettings>(empty);
  const [status, setStatus] = useState<ClaudeStatus | null>(null);
  const [prepared, setPrepared] = useState<PreparedClaudePlugin | null>(null);
  const [busy, setBusy] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState("");
  const operation = useRef(false);
  const connected = !!status?.subscriptionAuth && !status.pending;
  const models = connected ? status.models ?? [] : [];
  const blockers = !status || status.pending ? [] : [
    !status.supported && "The native Switchyard plugin is macOS-only for now; Windows requires a core helper port.",
    status.supported && status.installed && !status.compatibleVersion && `Update Claude Code to 2.1.301 or newer (installed: ${status.version || "unknown"}). Run claude update, then Check Claude account. Mods must be enabled.`,
    status.supported && status.compatibleVersion && !status.pluginAvailable && "The bundled Claude plugin is missing. Run python3 scripts/prepare-runtime.py --claude-plugin in desktop/.",
    (!settings.efficientModel || !settings.capableModel) && "Enter both Claude model IDs.",
  ].filter((blocker): blocker is string => !!blocker);

  // Restore the saved setup and re-check the account once at startup. Credentials
  // stay with Claude Code (in its own store); `auth status` only reports who is
  // signed in, so a previous sign-in is recognized without signing in again.
  useEffect(() => {
    if (!native) return;
    let active = true;
    api.claudeSettings().then(async (saved) => {
      if (!active) return;
      setSettings(saved); setLoaded(true);
      try {
        const next = await api.claudeStatus(saved);
        if (active) setStatus((current) => current ?? next);
      } catch { /* Claude Code missing or unsupported: stay quiet until the user checks explicitly. */ }
    }).catch((reason: unknown) => { if (active) setError(String(reason)); });
    return () => { active = false; };
  }, []);

  useEffect(() => {
    if (!status?.pending) return;
    let active = true;
    let timer: ReturnType<typeof setTimeout>;
    async function poll() {
      try {
        const next = await api.claudeStatus(settings);
        if (active) { setStatus(next); if (next.pending) timer = setTimeout(() => void poll(), 2000); }
      } catch (reason) { if (active) { setError(String(reason)); setStatus(null); } }
    }
    timer = setTimeout(() => void poll(), 2000);
    return () => { active = false; clearTimeout(timer); };
  }, [status?.pending, settings]);

  async function perform(action: () => Promise<void>) {
    if (operation.current) return;
    operation.current = true; setBusy(true); setError("");
    try { await action(); } catch (reason) { setError(String(reason)); }
    finally { operation.current = false; setBusy(false); }
  }
  function change(update: Partial<ClaudeSettings>) { setSettings((old) => ({ ...old, ...update })); setPrepared(null); if (update.executable !== undefined) setStatus(null); }

  return <section className={`model-discovery claude-integration${open ? " open" : ""}`}>
    <div className="discovery-bar"><span className={`discovery-state${connected ? " ready" : ""}`}>{connected && <i aria-hidden="true" />}{connected ? `Claude subscription connected${status.version ? ` · ${status.version}` : ""}` : "Claude Code subscription routing"}</span><button type="button" className="button secondary small" aria-expanded={open} onClick={() => setOpen(!open)}>{open ? "Close Claude setup" : "Set up Claude"}</button></div>
    {open && <div className="discovery-body">
      <p>Claude Code handles your subscription and model calls. Switchyard selects between two Claude models using its bundled native plugin; credentials are never copied. This is separate from the Codex proxy above.</p>
      <fieldset disabled={!native || !loaded || busy || !!status?.pending}><legend className="sr-only">Claude Code setup</legend>
        <div className="discovery-row"><label>Claude Code executable (optional absolute path)<input value={settings.executable} onChange={(event) => change({ executable: event.target.value })} placeholder="claude from PATH" /></label><button type="button" className="button secondary" onClick={() => void perform(async () => { setStatus(await api.claudeStatus(settings)); })}>Check Claude account</button><button type="button" className="button secondary" onClick={() => void perform(async () => { setStatus(await api.claudeLogin(settings)); })}>{status?.signedIn ? "Sign in again" : "Sign in with Claude Code"}</button></div>
        <div className="discovery-row"><label>Efficient Claude model ID<input value={settings.efficientModel} onChange={(event) => change({ efficientModel: event.target.value })} placeholder="claude-..." list="claude-account-models" autoComplete="off" spellCheck={false} /></label><label>Capable Claude model ID<input value={settings.capableModel} onChange={(event) => change({ capableModel: event.target.value })} placeholder="claude-..." list="claude-account-models" autoComplete="off" spellCheck={false} /></label></div>
        {models.length > 0 && <div className="claude-models"><p className="quiet-note">{models.length} models available to your Claude account. Pick one for each tier.</p>
          <ul>{models.map((model) => <li key={model.id} className={model.recommended ? "recommended" : undefined}><strong>{model.name}</strong><code>{model.id}</code>
            <button type="button" className="text-button" aria-pressed={settings.efficientModel === model.id} aria-label={`Use ${model.name} as efficient model`} onClick={() => change({ efficientModel: model.id })}>Efficient</button>
            <button type="button" className="text-button" aria-pressed={settings.capableModel === model.id} aria-label={`Use ${model.name} as capable model`} onClick={() => change({ capableModel: model.id })}>Capable</button></li>)}</ul>
          <datalist id="claude-account-models">{models.map((model) => <option key={model.id} value={model.id}>{model.name}</option>)}</datalist></div>}
        {connected && models.length === 0 && <p className="quiet-note">Claude Code has not cached a model list for this account yet. Start claude once, then Check Claude account, or enter model IDs manually.</p>}
        <p className="quiet-note">Enter model IDs available to your Claude account. Routing uses the bundled Composite policy, not the Codex strategy editor. Claude Code 2.1.301+ with mods enabled is required.</p>
        <div className="discovery-row"><button type="button" className="button secondary" disabled={!status?.subscriptionAuth || !status.pluginAvailable || !settings.efficientModel || !settings.capableModel} onClick={() => void perform(async () => { setPrepared(await api.prepareClaude(settings)); })}>Prepare Claude routing</button></div>
        {status?.subscriptionAuth && blockers.length > 0 && <div className="claude-blockers" role="note"><p>Prepare Claude routing is unavailable:</p><ul>{blockers.map((blocker) => <li key={blocker}>{blocker}</li>)}</ul></div>}
      </fieldset>
      {status?.pending && <button type="button" className="text-button" disabled={busy} onClick={() => void perform(async () => setStatus(await api.claudeCancelLogin()))}>Cancel Claude sign-in</button>}
      {status?.message && <p className="quiet-note" role="status">{status.message}</p>}
      {prepared && <div className="credential-editor"><p>Run this command in the project directory. Claude Code may ask you to trust the plugin. Use <code>/switchyard</code> for its actual status; <code>/switchyard off</code> pauses it.</p><code className="claude-command">{prepared.command}</code><button type="button" className="text-button" onClick={() => void navigator.clipboard.writeText(prepared.command).catch((reason: unknown) => setError(String(reason)))}>Copy command</button></div>}
      {error && <p className="editor-warning" role="alert">{error}</p>}
    </div>}
  </section>;
}
