import { useRef, useState } from "react";
import { api, native, servingTargets, type RouteSettings } from "./api";

export function ModelDiscovery({ settings, disabled, change }: { settings: RouteSettings; disabled: boolean; change: (settings: Partial<RouteSettings>) => void }) {
  const models = settings.discoveredModels ?? [];
  const executable = settings.codexExecutable ?? "";
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const operation = useRef(false);
  async function discover() {
    if (operation.current) return;
    operation.current = true; setBusy(true); setError("");
    try { change({ discoveredModels: await api.discoverModels(executable) }); }
    catch (reason) { setError(String(reason)); }
    finally { operation.current = false; setBusy(false); }
  }
  function useCapabilities() {
    const assigned = [...servingTargets(settings), ...(settings.additionalTargets ?? [])];
    const selected = assigned.map((target) => models.find((model) => model.id === target.model));
    const complete = selected.length > 0 && selected.every(Boolean);
    change({ vision: complete && selected.every((model) => model!.supportsImages), contextWindow: complete && selected.every((model) => model!.contextWindow) ? Math.min(...selected.map((model) => model!.contextWindow!)) : null });
  }
  return <section className={`model-discovery${open ? " open" : ""}`}>
    <div className="discovery-bar">
      <span className={`discovery-state${models.length ? " ready" : ""}`}>{models.length > 0 && <i aria-hidden="true" />}{models.length ? `${models.length} account models are suggested in the fields below` : "Fill model IDs faster from your Codex account"}</span>
      <button type="button" className="button secondary small" aria-expanded={open} onClick={() => setOpen(!open)}>{open ? "Close" : models.length ? "Manage account models" : "Load account models"}</button>
    </div>
    {open && <div className="discovery-body">
      <p>Runs Codex app-server with your existing CODEX_HOME account. Tokens are not shown here or copied to LiteLLM. Nothing runs until you click Discover models.</p>
      <fieldset disabled={disabled || busy}><legend className="sr-only">Model discovery</legend>
        <div className="discovery-row"><label>Codex executable (optional absolute path)<input value={executable} onChange={(event) => change({ codexExecutable: event.target.value })} placeholder="codex from PATH" /></label>
          <button type="button" className="button secondary" disabled={!native} onClick={() => void discover()}>{busy ? "Discovering models..." : "Discover models"}</button></div>
        {models.length > 0 && <><div className="discovery-row"><p>{models.length} models reported.</p><button type="button" className="button secondary" onClick={useCapabilities}>Use their context and image limits</button></div>
          <ul>{models.map((model) => <li key={model.id}><strong>{model.displayName}</strong><code>{model.id}</code><span>{model.supportsImages ? "images" : "text"} · {model.contextWindow?.toLocaleString() ?? "unknown"} context · {model.efforts.join(", ") || "effort not reported"}</span></li>)}</ul></>}
      </fieldset>{error && <p className="editor-warning" role="alert">{error}</p>}
    </div>}
    <datalist id="account-models">{models.map((model) => <option key={model.id} value={model.id}>{model.displayName}</option>)}</datalist>
  </section>;
}
