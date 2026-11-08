import { useEffect, useRef, useState } from "react";
import { algorithms, api, builtInRoles, emptySettings, native, stopped, validationMessage, type Algorithm, type ConfigurationPreview, type LoginStatus, type RouteSettings, type RuntimeStatus, type Stats } from "./api";

import { ModelDiscovery } from "./ModelDiscovery";
import { ClaudeIntegration } from "./ClaudeIntegration";
import { SetupTransfer } from "./SetupTransfer";
import { RequestHistory } from "./RequestHistory";
import { Activity } from "./Activity";
import { RoutingToggle, canAnimate, minimumHold, type RoutingPhase } from "./RoutingToggle";
import { AdvancedSettings, RolesEditor, RoutingEditor, StrategyPicker, strategyReset } from "./RoutingEditor";

type Page = "activity" | "requests" | "routing" | "roles";

export function App() {
  const [page, setPage] = useState<Page>("routing");
  const [settings, setSettings] = useState<RouteSettings>(emptySettings);
  /** The settings as last read from or written to disk, to tell the user about unsaved edits. */
  const [persisted, setPersisted] = useState("");
  const [undo, setUndo] = useState<{ from: string; settings: RouteSettings } | null>(null);
  const [runtime, setRuntime] = useState<RuntimeStatus>({ available: false, platform: "Not connected", missing: [] });
  const [session, setSession] = useState(stopped);
  const [login, setLogin] = useState<LoginStatus>({ pending: false, signedIn: false, code: null, verificationUrl: null, message: "" });
  const [stats, setStats] = useState<Stats | null>(null);
  const [preview, setPreview] = useState<ConfigurationPreview | null>(null);
  const [previewTab, setPreviewTab] = useState<keyof ConfigurationPreview>("switchyard");
  const [busy, setBusy] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [statsError, setStatsError] = useState("");
  const [copied, setCopied] = useState<"endpoint" | "command" | null>(null);
  const [transition, setTransition] = useState<"starting" | "stopping" | null>(null);
  const operation = useRef(false);
  const previewDialog = useRef<HTMLDialogElement>(null);
  const invalid = validationMessage(settings);

  useEffect(() => {
    if (!native) return;
    let mounted = true;
    api.bootstrap().then((data) => {
      if (!mounted) return;
      setSettings(data.settings); setPersisted(JSON.stringify(data.settings)); setRuntime(data.runtime); setSession(data.session); setLogin(data.login); setLoaded(true);
    }).catch((reason: unknown) => { if (mounted) setError(String(reason)); });
    return () => { mounted = false; };
  }, []);

  useEffect(() => {
    if (!native || !session.running || busy) return;
    let mounted = true;
    let timer: ReturnType<typeof setTimeout>;
    async function poll() {
      try {
        const status = await api.status();
        if (!mounted) return;
        setSession(status);
        if (!status.running) { setStats(null); return; }
        const next = await api.stats();
        if (mounted) { setStats(next); setStatsError(""); }
      } catch (reason) {
        if (mounted) { setStats(null); setStatsError(String(reason)); }
      }
      if (mounted) timer = setTimeout(poll, 2000);
    }
    void poll();
    return () => { mounted = false; clearTimeout(timer); };
  }, [session.running, busy]);

  async function perform(action: () => Promise<void>) {
    if (operation.current) return;
    operation.current = true; setBusy(true); setError(""); setNotice("");
    try { await action(); } catch (reason) { setError(String(reason)); }
    finally { operation.current = false; setBusy(false); }
  }

  useEffect(() => {
    if (!native || !login.pending) return;
    let mounted = true;
    let timer: ReturnType<typeof setTimeout>;
    async function pollLogin() {
      try {
        const status = await api.loginStatus();
        if (!mounted) return;
        setLogin(status);
        if (status.pending) timer = setTimeout(pollLogin, 1000);
      } catch (reason) {
        if (mounted) { setLogin({ pending: false, signedIn: false, code: null, verificationUrl: null, message: "" }); setError(String(reason)); }
      }
    }
    timer = setTimeout(pollLogin, 1000);
    return () => { mounted = false; clearTimeout(timer); };
  }, [login.pending]);

  function change(next: Partial<RouteSettings>) {
    setSettings((previous) => ({ ...previous, ...next })); setNotice(""); setPreview(null); setUndo(null);
  }

  /** Switching strategy resets strategy-specific inputs, so the previous setup stays one click away. */
  function pickStrategy(value: Algorithm) {
    const previous = settings;
    change(strategyReset(value));
    setUndo({ from: algorithms.find((item) => item.value === previous.algorithm)!.label, settings: previous });
  }

  async function showPreview() {
    await perform(async () => {
      const result = await api.preview(settings);
      setPreview(result);
      previewDialog.current?.showModal();
    });
  }

  /** The control keeps a start or stop showing until its glyph has played out. */
  async function toggleRouting() {
    if (operation.current) return;
    const transition = session.running ? "stopping" : "starting";
    const animate = canAnimate();
    const began = Date.now();
    setTransition(transition);
    await perform(async () => {
      if (transition === "stopping") {
        setSession(await api.stop()); setStats(null); setStatsError("");
      } else {
        await api.save(settings); setPersisted(JSON.stringify(settings));
        setSession(await api.start(settings)); setPage("activity");
      }
    });
    const rest = minimumHold[transition] - (Date.now() - began);
    if (animate && rest > 0) await new Promise((resolve) => setTimeout(resolve, rest));
    setTransition(null);
  }

  const selected = algorithms.find((algorithm) => algorithm.value === settings.algorithm)!;
  const connection = transition === "starting" ? "Starting routing…" : transition === "stopping" ? "Stopping routing…" : session.running ? "Routing on" : "Routing off";
  const routingPhase: RoutingPhase = transition ?? (session.running ? "running" : "idle");
  const locked = busy || session.running;
  const saveSettings = () => void perform(async () => { await api.save(settings); const saved = await api.bootstrap(); setSettings(saved.settings); setPersisted(JSON.stringify(saved.settings)); setUndo(null); setNotice("Routing settings saved and read back. Codex configuration is unchanged."); });
  const dirty = loaded && JSON.stringify(settings) !== persisted;
  const canStart = native && loaded && !session.running && runtime.available && (settings.algorithm === "noop" || login.signedIn) && !login.pending && !invalid;
  const signIn = () => void perform(async () => setLogin(await api.beginLogin()));
  const showIssue = () => {
    const field = document.querySelector<HTMLElement>(".routing-page [aria-invalid=true]");
    field?.closest("details")?.setAttribute("open", "");
    field?.scrollIntoView?.({ block: "center", behavior: canAnimate() ? "smooth" : "auto" }); field?.focus({ preventScroll: true });
  };
  const readiness: { tone: "ok" | "warn" | "live"; text: string; action?: { label: string; run: () => void } } =
    session.running ? { tone: "live", text: "Routing is live. Stop it in the toolbar to change these settings." }
    : !native ? { tone: "warn", text: "Browser preview. Open the desktop app to save settings or start routing." }
    : !loaded ? { tone: "warn", text: error ? "Saved settings could not be read, so nothing can be saved." : "Reading saved settings…" }
    : !runtime.available ? { tone: "warn", text: "The bundled runtime is not prepared yet." }
    : login.pending ? { tone: "warn", text: "Finish ChatGPT sign-in to start routing." }
    : settings.algorithm !== "noop" && !login.signedIn ? { tone: "warn", text: "Sign in with ChatGPT to start routing.", action: { label: "Sign in", run: signIn } }
    : invalid ? { tone: "warn", text: invalid, action: { label: "Show", run: showIssue } }
    : dirty ? { tone: "ok", text: "Ready to start. You have unsaved changes; starting saves them." }
    : { tone: "ok", text: "Ready to start. Settings are saved." };
  const saveLibrary = () => void perform(async () => { await api.saveLibrary(settings.roles ?? builtInRoles, settings.roleGroups ?? []); setNotice("Role library saved. Unsaved route inputs are unchanged."); });
  async function copyText(text: string, what: "endpoint" | "command") {
    try { await navigator.clipboard.writeText(text); setCopied(what); setTimeout(() => setCopied(null), 1600); }
    catch (reason) { setError(String(reason)); }
  }
  const nav = (id: Page, label: string) => <button className={page === id ? "pane-tab selected" : "pane-tab"} aria-current={page === id ? "page" : undefined} onClick={() => setPage(id)}>{label}</button>;

  return <div className="app-shell">
    <header className="toolbar">
        <span className="toolbar-brand"><i className={session.running ? "live" : ""} aria-hidden="true" />Switchyard</span>
        <nav className="pane-switcher" aria-label="Main navigation">{nav("routing", "Routing")}{nav("roles", "Roles")}{nav("activity", "Activity")}{nav("requests", "Requests")}</nav>
        <span className="toolbar-spacer" />
        <span className={`toolbar-status${session.running ? " live" : ""}`}>{connection}</span>
        <RoutingToggle phase={routingPhase} onToggle={() => void toggleRouting()}
          disabled={!native || !loaded || (!session.running && (!runtime.available || (settings.algorithm !== "noop" && !login.signedIn) || login.pending || !!invalid))} />
      </header>
    <main>
      {!native && <div className="banner preview-banner" role="status"><strong>Browser preview</strong><span>Layout only. Open the Tauri app to save settings or control the bundled services. No simulated metrics.</span></div>}
      {native && loaded && !runtime.available && <div className="banner" role="status"><strong>Runtime not prepared</strong><span>{runtime.missing.join(" · ")}. Run <code>npm run runtime</code> in <code>desktop/</code>, then reopen the app.</span></div>}
      {error && <div className="banner error" role="alert"><strong>Action could not complete</strong><span>{error}</span><button onClick={() => setError("")} aria-label="Dismiss error">×</button></div>}
      {notice && <div className="banner success" role="status">{notice}</div>}
      {page === "routing" && session.running && <div className="banner" role="status"><strong>Routing is live</strong><span>Stop routing to change the configuration.</span></div>}
      {page === "routing" ? <div className="config-page routing-page" key="routing">
        <section className="config-head">
          <div><h1>Routing</h1>
            <p className="flow-line" aria-label="Request flow"><span>Codex</span><i aria-hidden="true">→</i><strong>Switchyard · {selected.label}</strong><i aria-hidden="true">→</i><span>ChatGPT models</span></p></div>
          <div className={`account-chip${login.signedIn ? " ok" : ""}`}>
            <span className="account-state"><i aria-hidden="true" />{login.pending ? "Waiting for sign-in" : login.signedIn ? "ChatGPT connected" : "ChatGPT not connected"}</span>
            {login.pending ? <button className="text-button" onClick={() => void perform(async () => setLogin(await api.cancelLogin()))}>Cancel sign-in</button>
              : <button className={login.signedIn ? "text-button" : "button primary small"} disabled={!native || !loaded || busy || session.running || !runtime.available} onClick={signIn}>{login.signedIn ? "Sign in again" : "Sign in with ChatGPT"}</button>}
          </div>
        </section>
        {login.pending && <div className="device-login" role="status"><span>Code</span><strong className="device-code">{login.code ?? "..."}</strong>{login.code && <p>Open <strong>https://auth.openai.com/codex/device</strong> in your browser and enter this code. Never share it.</p>}</div>}
        <section className="route-panel" aria-label="Route">
          <StrategyPicker settings={settings} disabled={locked} onPick={pickStrategy} />
          {undo && <div className="switch-notice" role="status"><span>Switched from <strong>{undo.from}</strong>. Judge, extra targets and route TOML were reset; your models and roles stayed.</span><button type="button" className="text-button" onClick={() => { const previous = undo.settings; change(previous); }}>Undo</button></div>}
          <div className="route-body">
            <header className="route-body-head"><h2>Models</h2><p>Each card says what that model does in {selected.label}. Enter model IDs your ChatGPT plan offers; requests run through the ChatGPT account you sign in with above.</p></header>
            <ModelDiscovery settings={settings} change={change} disabled={locked || !loaded} />
            <RoutingEditor key={settings.algorithm} settings={settings} change={change} disabled={locked} />
            <AdvancedSettings settings={settings} change={change} disabled={locked} />
          </div>
        </section>
        <section className="connect-panel" aria-label="Use it from Codex">
          <h2>Use it from Codex</h2>
          <ol className="connect-steps">
            <li><span className="connect-index">1</span><div><strong>Start routing</strong><p>Press <b>Save and start</b> below. The toolbar switch does the same; both save first.</p></div></li>
            <li><span className="connect-index">2</span><div><strong>Run Codex with the Switchyard profile</strong>
              <div className="endpoint-row command-row"><code>codex --profile switch</code><button className="button secondary" onClick={() => void copyText("codex --profile switch", "command")}>{copied === "command" ? "Copied" : "Copy"}</button></div></div></li>
          </ol>
          <div className="endpoint-line"><span>Endpoint for other clients</span><code>{session.endpoint}</code><button className="text-button" onClick={() => void copyText(session.endpoint, "endpoint")}>{copied === "endpoint" ? "Copied" : "Copy"}</button></div>
          <p className="quiet-note">Start routing adds a temporary <code>switch.config.toml</code> to your Codex home for this command and Stop removes it. Your own config.toml is never edited, and a profile file you wrote yourself is never replaced.</p>
        </section>
        <section className="other-integrations" aria-label="Other integrations">
          <h2>Other integrations</h2>
          <ClaudeIntegration />
        </section>
      </div> : page === "roles" ? <div className="config-page" key="roles">
        <section className="config-head"><div><h1>Roles</h1><p className="flow-line">Reusable descriptions and prompts for your models, plus setup transfer.</p></div></section>
        <RolesEditor settings={settings} change={change} disabled={locked} />
        <SetupTransfer settings={settings} disabled={locked || !loaded} onImport={(imported) => change(imported)} />
      </div> : page === "requests" ? <RequestHistory running={session.running} settings={settings} /> : <Activity settings={settings} stats={stats} statsError={statsError} running={session.running} onOpenRequests={() => setPage("requests")} onConfigure={() => setPage("routing")} />}
      {page === "routing" ? <footer className={`route-bar ${readiness.tone}`}>
        <p className="route-status" role="status"><i aria-hidden="true" /><span>{busy ? "Working with the local runtime…" : readiness.text}</span>
          {!busy && readiness.action && <button type="button" className="text-button" onClick={readiness.action.run}>{readiness.action.label}</button>}</p>
        <div className="actions">
          <button className="button ghost" disabled={!native || !loaded || busy || !!invalid} onClick={() => void showPreview()}>Review configuration</button>
          <button className="button secondary" disabled={!native || !loaded || locked || !!invalid} onClick={saveSettings}>Save settings{dirty && <i className="dirty-dot" aria-hidden="true" title="Unsaved changes" />}</button>
          {!session.running && <button className="button primary" disabled={busy || !canStart} onClick={() => void toggleRouting()}>Save and start</button>}
        </div>
      </footer> : <footer className="action-bar"><div><span className={`runtime-dot ${runtime.available ? "ready" : ""}`} /><div><strong>{busy ? "Working with the local runtime..." : session.running ? "Local services are running" : runtime.available ? "Bundled runtime ready" : "Bundled runtime required"}</strong><small>{native ? runtime.platform : "Launch with npm run desktop"}</small></div></div><div className="actions">
        {page === "roles" && <button className="button secondary" disabled={!native || !loaded || locked} onClick={saveLibrary}>Save role library</button>}
</div></footer>}
    </main>
    <dialog ref={previewDialog} className="preview-dialog" onClick={(event) => { if (event.target === event.currentTarget) previewDialog.current?.close(); }}><div className="dialog-heading"><div><div className="eyebrow">REVIEW BEFORE APPLYING</div><h2>Generated configuration</h2></div><button aria-label="Close configuration" className="close-button" onClick={() => previewDialog.current?.close()}>×</button></div><div className="preview-tabs" role="tablist" aria-label="Configuration files">{(["switchyard", "litellm", "codex"] as const).map((tab) => <button key={tab} role="tab" aria-selected={previewTab === tab} aria-controls="configuration-code" id={`tab-${tab}`} onClick={() => setPreviewTab(tab)}>{tab === "switchyard" ? "routes.toml" : tab === "litellm" ? "litellm.json" : "Codex snippet"}</button>)}</div><pre id="configuration-code" role="tabpanel" aria-labelledby={`tab-${previewTab}`} tabIndex={0}><code>{preview?.[previewTab]}</code></pre><p className="dialog-note">Review does not write files. Starting routing creates a temporary Codex profile only when enabled; config.toml is never edited.</p></dialog>
  </div>;
}
