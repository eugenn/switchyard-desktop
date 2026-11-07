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

  useEffect(() => {
    if (!native || !open) return;
    let active = true;
    api.claudeSettings().then((saved) => { if (active) { setSettings(saved); setLoaded(true); } }).catch((reason: unknown) => { if (active) setError(String(reason)); });
    return () => { active = false; };
  }, [open]);

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
    <div className="discovery-bar"><span className="discovery-state">Claude Code subscription routing</span><button type="button" className="button secondary small" aria-expanded={open} onClick={() => setOpen(!open)}>{open ? "Close Claude setup" : "Set up Claude"}</button></div>
    {open && <div className="discovery-body">
      <p>Claude Code handles your subscription and model calls. Switchyard selects between two Claude models using its bundled native plugin; credentials are never copied. This is separate from the Codex proxy above.</p>
      <fieldset disabled={!native || !loaded || busy || !!status?.pending}><legend className="sr-only">Claude Code setup</legend>
        <div className="discovery-row"><label>Claude Code executable (optional absolute path)<input value={settings.executable} onChange={(event) => change({ executable: event.target.value })} placeholder="claude from PATH" /></label><button type="button" className="button secondary" onClick={() => void perform(async () => { setStatus(await api.claudeStatus(settings)); })}>Check Claude account</button><button type="button" className="button secondary" onClick={() => void perform(async () => { setStatus(await api.claudeLogin(settings)); })}>Sign in with Claude Code</button></div>
        <div className="discovery-row"><label>Efficient Claude model ID<input value={settings.efficientModel} onChange={(event) => change({ efficientModel: event.target.value })} placeholder="claude-..." /></label><label>Capable Claude model ID<input value={settings.capableModel} onChange={(event) => change({ capableModel: event.target.value })} placeholder="claude-..." /></label></div>
        <p className="quiet-note">Enter model IDs available to your Claude account. Routing uses the bundled Composite policy, not the Codex strategy editor. Claude Code 2.1.301+ with mods enabled is required.</p>
        <div className="discovery-row"><button type="button" className="button secondary" disabled={!status?.subscriptionAuth || !status.pluginAvailable || !settings.efficientModel || !settings.capableModel} onClick={() => void perform(async () => { setPrepared(await api.prepareClaude(settings)); })}>Prepare Claude routing</button></div>
      </fieldset>
      {status?.pending && <button type="button" className="text-button" disabled={busy} onClick={() => void perform(async () => setStatus(await api.claudeCancelLogin()))}>Cancel Claude sign-in</button>}
      {status?.message && <p className="quiet-note" role="status">{status.message}{status.version ? ` ${status.version}` : ""}</p>}
      {prepared && <div className="credential-editor"><p>Run this command in the project directory. Claude Code may ask you to trust the plugin. Use <code>/switchyard</code> for its actual status; <code>/switchyard off</code> pauses it.</p><code className="claude-command">{prepared.command}</code><button type="button" className="text-button" onClick={() => void navigator.clipboard.writeText(prepared.command).catch((reason: unknown) => setError(String(reason)))}>Copy command</button></div>}
      {error && <p className="editor-warning" role="alert">{error}</p>}
    </div>}
  </section>;
}
