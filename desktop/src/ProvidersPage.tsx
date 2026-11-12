import { useRef, useState, type ReactNode } from "react";
import { connectionInfo, native, type AvailableModel, type Connection, type ConnectionId, type KeyedConnection, type LoginStatus, type RouteSettings } from "./api";
import { ModelDiscovery } from "./ModelDiscovery";
import { connectionUsage } from "./RouteCanvas";

type Id = ConnectionId | "typesafe";

const blurbs: Record<Id, string> = {
  chatgpt: "Models in your ChatGPT plan, through the Codex sign-in. No per-token bill.",
  openai: "Every OpenAI model, billed per token to your API account.",
  anthropic: "Claude models, billed per token. A Claude subscription does not include API access.",
  openrouter: "Hundreds of models from many vendors with one key, plus the Mercury Decide judge.",
  typesafe: "The Jev decision model for task judges.",
};

const marks: Record<Id, string> = { chatgpt: "C", openai: "O", anthropic: "A", openrouter: "R", typesafe: "J" };

function ago(seconds: number | null) {
  if (!seconds) return "";
  const minutes = Math.round((Date.now() / 1000 - seconds) / 60);
  return minutes < 1 ? "just now" : minutes < 60 ? `${minutes} min ago` : minutes < 1440 ? `${Math.round(minutes / 60)} h ago` : `${Math.round(minutes / 1440)} d ago`;
}

/**
 * The first step: connect the providers you have, by sign-in or API key.
 * Routing then picks models from any connected provider.
 */
export function ProvidersPage({ settings, change, connections, login, disabled, signInDisabled, onSignIn, onCancelSignIn, onSaveKey, onRefresh, onContinue }: {
  settings: RouteSettings; change: (next: Partial<RouteSettings>) => void; connections: Connection[]; login: LoginStatus; disabled: boolean; signInDisabled: boolean;
  onSignIn: () => void; onCancelSignIn: () => void; onSaveKey: (id: KeyedConnection, key: string) => Promise<void>; onRefresh: (id: KeyedConnection) => Promise<void>; onContinue: () => void;
}) {
  const usage = connectionUsage(settings);
  const byId = (id: Id) => connections.find((item) => item.id === id);
  const chatgptConnected = login.signedIn;
  const anyConnected = chatgptConnected || connections.some((item) => item.id !== "typesafe" && item.id !== "chatgpt" && item.connected);
  const card = (id: KeyedConnection, extra?: ReactNode) => <KeyCard key={id} id={id} connection={byId(id)} used={usage[id]} disabled={disabled} onSave={onSaveKey} onRefresh={onRefresh}>{extra}</KeyCard>;

  return <div className="config-page providers-page" key="providers">
    <section className="config-head providers-head">
      <div><h1>Providers</h1><p className="flow-line">Connect the model providers you have. Routing can then mix models from any of them.</p></div>
      {anyConnected && <button type="button" className="button primary" onClick={onContinue}>Continue to routing</button>}
    </section>

    <section className="providers-section" aria-label="Chat model providers">
      <header><h2>Chat models</h2><p>Each model in Routing names the connection that serves it, so you always know how it is billed.</p></header>
      <div className="providers-grid">
        <ProviderCard id="chatgpt" used={usage.chatgpt} state={login.pending ? "pending" : chatgptConnected ? "connected" : "idle"}
          status={login.pending ? "Waiting for sign-in" : chatgptConnected ? "Signed in with ChatGPT" : "Not connected"}>
          {login.pending && <div className="device-login" role="status"><span>Code</span><strong className="device-code">{login.code ?? "..."}</strong>{login.code && <p>Open <strong>auth.openai.com/codex/device</strong> and enter this code. Never share it.</p>}</div>}
          <div className="card-actions">
            {login.pending ? <button className="text-button" onClick={onCancelSignIn}>Cancel sign-in</button>
              : <button className={chatgptConnected ? "button secondary small" : "button primary small"} disabled={signInDisabled} onClick={onSignIn}>{chatgptConnected ? "Sign in again" : "Sign in with ChatGPT"}</button>}
          </div>
          <ModelDiscovery settings={settings} change={change} disabled={disabled} />
        </ProviderCard>
        {card("openai")}
        {card("anthropic", <p className="card-note">Shared with the Claude Code integration.</p>)}
        {card("openrouter")}
      </div>
    </section>

    <section className="providers-section" aria-label="Decision model providers">
      <header><h2>Decision models</h2><p>Fast judges that return a probability for each choice. Mercury Decide uses your OpenRouter key.</p></header>
      <div className="providers-grid">{card("typesafe")}</div>
    </section>
  </div>;
}

function ProviderCard({ id, used, state, status, children }: { id: Id; used: string[]; state: "connected" | "failed" | "pending" | "idle" | "needed"; status: string; children: ReactNode }) {
  return <section className={`provider-card ${id} ${state}`} aria-label={connectionInfo[id].name}>
    <header>
      <span className="provider-mark" aria-hidden="true">{marks[id]}</span>
      <span className="provider-title"><strong>{connectionInfo[id].name}</strong><em className={`billing ${connectionInfo[id].billing.toLowerCase()}`}>{connectionInfo[id].billing === "Key" ? "Decision" : connectionInfo[id].billing}</em></span>
      <span className="provider-status" role="status"><i aria-hidden="true" />{status}</span>
    </header>
    <p className="provider-blurb">{blurbs[id]}</p>
    {children}
    <footer className="provider-used">{used.length ? <>Used by {compactUse(used).map((name) => <span key={name} className={`use-dot ${useTone(name)}`}><i aria-hidden="true" />{name}</span>)}</> : "Not used in the current route"}</footer>
  </section>;
}

function KeyCard({ id, connection, used, disabled, onSave, onRefresh, children }: {
  id: KeyedConnection; connection?: Connection; used: string[]; disabled: boolean; onSave: (id: KeyedConnection, key: string) => Promise<void>; onRefresh: (id: KeyedConnection) => Promise<void>; children?: ReactNode;
}) {
  const [key, setKey] = useState("");
  const [editing, setEditing] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [busy, setBusy] = useState<"" | "save" | "check">("");
  const [error, setError] = useState("");
  const operation = useRef(false);
  const connected = !!connection?.connected;
  const failed = connected && !!connection?.error;
  async function run(kind: "save" | "check", action: () => Promise<void>) {
    if (operation.current) return;
    operation.current = true; setBusy(kind); setError("");
    try { await action(); }
    catch (reason) { setError(String(reason)); }
    finally { operation.current = false; setBusy(""); }
  }
  const save = (value: string) => run("save", async () => { await onSave(id, value); setKey(""); setEditing(false); setConfirming(false); if (value && id !== "typesafe") await onRefresh(id); });
  const state = !native ? "idle" : failed ? "failed" : connected ? "connected" : used.length ? "needed" : "idle";
  const status = !native ? "Shows in the desktop app" : failed ? "Check failed" : connected ? `Connected${connection?.keyHint ? ` · key …${connection.keyHint}` : ""}` : used.length ? "Key needed to start" : "Not connected";
  return <ProviderCard id={id} used={used} state={state} status={status}>
    {(!connected || editing) ? <form className="key-form" onSubmit={(event) => { event.preventDefault(); if (key.trim()) void save(key.trim()); }}>
      <input type="password" autoComplete="off" spellCheck={false} aria-label={`${connectionInfo[id].name} API key`} placeholder="Paste API key" value={key} disabled={!native || disabled || !!busy} onChange={(event) => setKey(event.target.value)} />
      <button type="submit" className="button primary small" disabled={!native || disabled || !!busy || !key.trim()}>{busy === "save" ? "Saving…" : "Connect"}</button>
      {editing && <button type="button" className="text-button" onClick={() => { setEditing(false); setKey(""); }}>Cancel</button>}
    </form> : <div className="card-actions">
      {id !== "typesafe" && <button type="button" className="button secondary small" disabled={!native || !!busy} onClick={() => void run("check", () => onRefresh(id))}>{busy === "check" ? "Checking…" : "Check connection"}</button>}
      <button type="button" className="text-button" disabled={!native || disabled} onClick={() => setEditing(true)}>Replace key</button>
      {confirming ? <span className="confirm-line" role="group" aria-label="Confirm disconnect">{used.length ? `${used.length} model${used.length > 1 ? "s" : ""} in the route use this.` : "Remove the key?"}
        <button type="button" className="text-button danger" onClick={() => void save("")}>Disconnect</button><button type="button" className="text-button" onClick={() => setConfirming(false)}>Keep</button></span>
        : <button type="button" className="text-button danger" disabled={!native || disabled} onClick={() => setConfirming(true)}>Disconnect</button>}
    </div>}
    {connected && id !== "typesafe" && <CheckLine connection={connection!} />}
    {connected && id !== "typesafe" && (connection?.models.length ?? 0) > 0 && <ModelList models={connection!.models} />}
    {(error || (failed && connection?.error)) && <p className="editor-warning" role="alert">{error || connection?.error}</p>}
    {children}
    <p className="key-note">Kept in the system credential vault, never in setup files.</p>
  </ProviderCard>;
}

function CheckLine({ connection }: { connection: Connection }) {
  if (!connection.checkedAt) return <p className="check-line">Not checked yet. Checking lists the models for free.</p>;
  return <p className="check-line">{connection.error ? `Last check failed ${ago(connection.checkedAt)}` : `${connection.models.length} models · ${connection.latencyMs ?? "?"} ms · checked ${ago(connection.checkedAt)}`}</p>;
}

function ModelList({ models }: { models: AvailableModel[] }) {
  const [search, setSearch] = useState("");
  const shown = models.filter((model) => !search.trim() || `${model.id} ${model.displayName}`.toLowerCase().includes(search.trim().toLowerCase()));
  return <details className="model-list">
    <summary>Browse {models.length} models</summary>
    <input type="search" aria-label="Search models" placeholder="Search models" value={search} onChange={(event) => setSearch(event.target.value)} />
    <ul>{shown.slice(0, 200).map((model) => <li key={model.id}><code>{model.id}</code>{model.displayName !== model.id && <span>{model.displayName}</span>}</li>)}</ul>
    {shown.length > 200 && <p className="key-note">Showing 200 of {shown.length}. Search to narrow.</p>}
  </details>;
}

export function compactUse(used: string[]) {
  const numbered = used.filter((name) => /^Target \d+$/.test(name));
  return numbered.length > 2 ? [`${numbered.length} targets`, ...used.filter((name) => !numbered.includes(name))] : used;
}

export function useTone(name: string) {
  return name === "Efficient" || name === "Executor" || name === "Model" ? "efficient" : name === "Capable" ? "capable" : name === "Judge" || name === "Advisor" ? "judge" : "neutral";
}

/** Routing's compact view of connections: who is connected and who the route uses. */
export function ConnectionStrip({ connections, connected, usage, onHighlight, onManage }: {
  connections: Connection[]; connected: Set<ConnectionId | "typesafe">; usage: Record<ConnectionId | "typesafe", string[]>;
  onHighlight: (id: ConnectionId | "typesafe" | null) => void; onManage: () => void;
}) {
  const ids: Id[] = ["chatgpt", "openai", "anthropic", "openrouter", "typesafe"];
  const failed = (id: Id) => !!connections.find((item) => item.id === id)?.error;
  return <nav className="connection-strip" aria-label="Connections">
    <span className="strip-label">Providers</span>
    {ids.map((id) => {
      const on = connected.has(id);
      const used = usage[id].length > 0;
      if (!on && !used) return null;
      return <button type="button" key={id} className={`strip-chip ${id}${on ? " on" : " off"}${used ? " used" : ""}${failed(id) ? " failed" : ""}`}
        onMouseEnter={() => onHighlight(id)} onMouseLeave={() => onHighlight(null)} onFocus={() => onHighlight(id)} onBlur={() => onHighlight(null)} onClick={onManage}
        title={on ? `${connectionInfo[id].name}: connected${used ? ` · used by ${usage[id].join(", ")}` : ""}` : `${connectionInfo[id].name} is not connected`}>
        <i aria-hidden="true" />{connectionInfo[id].name}{used && <small>{compactUse(usage[id]).join(" · ")}</small>}{!on && <em>not connected</em>}
      </button>;
    })}
    <button type="button" className="text-button strip-manage" onClick={onManage}>{[...connected].length ? "Manage providers" : "Connect providers"}</button>
  </nav>;
}
