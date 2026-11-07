import { useEffect, useRef, useState, type ReactNode } from "react";
import { algorithms, api, builtInRoles, emptySettings, native, stopped, validationMessage, type ConfigurationPreview, type LoginStatus, type RouteSettings, type RuntimeStatus, type Stats } from "./api";

import { ModelDiscovery } from "./ModelDiscovery";
import { ClaudeIntegration } from "./ClaudeIntegration";
import { SetupTransfer } from "./SetupTransfer";
import { RequestHistory } from "./RequestHistory";
import { Activity } from "./Activity";
import { RoutingToggle, canAnimate, minimumHold, type RoutingPhase } from "./RoutingToggle";
import { AdvancedSettings, RolesEditor, RoutingEditor, StrategyPicker } from "./RoutingEditor";

type Page = "activity" | "requests" | "routing" | "roles";

export function App() {
  const [page, setPage] = useState<Page>("routing");
  const [settings, setSettings] = useState<RouteSettings>(emptySettings);
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
      setSettings(data.settings); setRuntime(data.runtime); setSession(data.session); setLogin(data.login); setLoaded(true);
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
    setSettings((previous) => ({ ...previous, ...next })); setNotice(""); setPreview(null);
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
  const saveSettings = () => void perform(async () => { await api.save(settings); const persisted = await api.bootstrap(); setSettings(persisted.settings); setNotice("Routing settings saved and read back. Codex configuration is unchanged."); });
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
      {page === "routing" ? <div className="config-page" key="routing">
        <section className="config-head">
          <div><h1>Routing</h1>
            <p className="flow-line" aria-label="Request flow"><span>Codex</span><i aria-hidden="true">→</i><strong>Switchyard · {selected.label}</strong><i aria-hidden="true">→</i><span>LiteLLM · ChatGPT</span></p></div>
          <div className={`account-chip${login.signedIn ? " ok" : ""}`}>
            <span className="account-state"><i aria-hidden="true" />{login.pending ? "Waiting for sign-in" : login.signedIn ? "ChatGPT connected" : "ChatGPT not connected"}</span>
            {login.pending ? <button className="text-button" onClick={() => void perform(async () => setLogin(await api.cancelLogin()))}>Cancel sign-in</button>
              : <button className={login.signedIn ? "text-button" : "button primary small"} disabled={!native || !loaded || busy || session.running || !runtime.available} onClick={() => void perform(async () => setLogin(await api.beginLogin()))}>{login.signedIn ? "Sign in again" : "Sign in with ChatGPT"}</button>}
          </div>
        </section>
        {login.pending && <div className="device-login" role="status"><span>Code</span><strong className="device-code">{login.code ?? "..."}</strong>{login.code && <p>Open <strong>https://auth.openai.com/codex/device</strong> in your browser and enter this code. Never share it.</p>}</div>}
        <ClaudeIntegration />
        {loaded && invalid && <div className="attention" role="status"><strong>Needs attention</strong><span>{invalid}</span></div>}
        <ol className="config-steps">
          <Step index={1} title="Strategy" hint="How each request picks a model. Switching resets strategy-specific inputs; models and roles stay.">
            <StrategyPicker settings={settings} change={change} disabled={locked} />
          </Step>
          <Step index={2} title="Models" hint="Exact model IDs from your account. A role is optional: it tells the judge what a model is for.">
            <ModelDiscovery settings={settings} change={change} disabled={locked || !loaded} />
            <RoutingEditor settings={settings} change={change} disabled={locked} />
            <AdvancedSettings settings={settings} change={change} disabled={locked} />
          </Step>
          <Step index={3} title="Connect" hint="Start routing, then launch Codex with the profile below.">
            <div className="endpoint-row"><code>{session.endpoint}</code><button className="button secondary" onClick={() => void copyText(session.endpoint, "endpoint")}>{copied === "endpoint" ? "Copied" : "Copy"}</button><button className="button secondary" disabled={!native || !loaded || busy || !!invalid} onClick={() => void showPreview()}>Review configuration <span aria-hidden="true">↗</span></button></div>
            <div className="endpoint-row command-row"><code>codex --profile switch</code><button className="button secondary" onClick={() => void copyText("codex --profile switch", "command")}>{copied === "command" ? "Copied" : "Copy"}</button></div>
            <p className="quiet-note">Start routing adds a temporary <code>switch.config.toml</code> to your Codex home for this command and Stop removes it. Your own config.toml is never edited, and a profile file you wrote yourself is never replaced.</p>
          </Step>
        </ol>
      </div> : page === "roles" ? <div className="config-page" key="roles">
        <section className="config-head"><div><h1>Roles</h1><p className="flow-line">Reusable descriptions and prompts for your models, plus setup transfer.</p></div></section>
        <RolesEditor settings={settings} change={change} disabled={locked} />
        <SetupTransfer settings={settings} disabled={locked || !loaded} onImport={(imported) => change(imported)} />
      </div> : page === "requests" ? <RequestHistory running={session.running} settings={settings} /> : <Activity settings={settings} stats={stats} statsError={statsError} running={session.running} onOpenRequests={() => setPage("requests")} onConfigure={() => setPage("routing")} />}
      <footer className="action-bar"><div><span className={`runtime-dot ${runtime.available ? "ready" : ""}`} /><div><strong>{busy ? "Working with the local runtime..." : session.running ? "Local services are running" : runtime.available ? "Bundled runtime ready" : "Bundled runtime required"}</strong><small>{native ? runtime.platform : "Launch with npm run desktop"}</small></div></div><div className="actions">
        {page === "routing" && <button className="button secondary" disabled={!native || !loaded || locked || !!invalid} onClick={saveSettings}>Save settings</button>}
        {page === "roles" && <button className="button secondary" disabled={!native || !loaded || locked} onClick={saveLibrary}>Save role library</button>}
</div></footer>
    </main>
    <dialog ref={previewDialog} className="preview-dialog" onClick={(event) => { if (event.target === event.currentTarget) previewDialog.current?.close(); }}><div className="dialog-heading"><div><div className="eyebrow">REVIEW BEFORE APPLYING</div><h2>Generated configuration</h2></div><button aria-label="Close configuration" className="close-button" onClick={() => previewDialog.current?.close()}>×</button></div><div className="preview-tabs" role="tablist" aria-label="Configuration files">{(["switchyard", "litellm", "codex"] as const).map((tab) => <button key={tab} role="tab" aria-selected={previewTab === tab} aria-controls="configuration-code" id={`tab-${tab}`} onClick={() => setPreviewTab(tab)}>{tab === "switchyard" ? "routes.toml" : tab === "litellm" ? "litellm.json" : "Codex snippet"}</button>)}</div><pre id="configuration-code" role="tabpanel" aria-labelledby={`tab-${previewTab}`} tabIndex={0}><code>{preview?.[previewTab]}</code></pre><p className="dialog-note">Review does not write files. Starting routing creates a temporary Codex profile only when enabled; config.toml is never edited.</p></dialog>
  </div>;
}

function Step({ index, title, hint, children }: { index: number; title: string; hint: string; children: ReactNode }) {
  return <li className="config-step"><div className="step-rail" aria-hidden="true"><span>{index}</span></div><section className="step-body" aria-label={title}><header><h2>{title}</h2><p>{hint}</p></header>{children}</section></li>;
}
