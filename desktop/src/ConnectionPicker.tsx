import { createContext, useId, useMemo, useState } from "react";
import { connectionIds, connectionInfo, type AvailableModel, type ConnectionId } from "./api";

export type Catalog = Partial<Record<ConnectionId, AvailableModel[]>>;

/** What Routing knows about connections: which are usable, their models, and how to connect more. */
export const ConnectionsContext = createContext<{ connected: Set<ConnectionId | "typesafe">; catalog: Catalog; onConnect?: () => void }>({ connected: new Set(), catalog: {} });

/**
 * One field for a model and the connection that serves it. Suggestions come
 * from every connected provider, grouped by connection with how it is billed.
 * Typing an unlisted ID keeps the current connection.
 */
export function ConnectionPicker({ label, connection, model, connected, catalog, invalid, placeholder, onChange, onConnectMore }: {
  label: string; connection: ConnectionId; model: string; connected: Set<ConnectionId | "typesafe">; catalog: Catalog; invalid?: boolean; placeholder?: string;
  onChange: (next: { connection: ConnectionId; model: string }) => void; onConnectMore?: () => void;
}) {
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(-1);
  // Opening shows every model; typing narrows the list.
  const [typed, setTyped] = useState(false);
  const menu = useId();
  const query = model.trim().toLowerCase();
  const groups = useMemo(() => connectionIds.filter((id) => connected.has(id)).map((id) => ({
    id, models: (catalog[id] ?? []).filter((item) => !typed || !query || item.id.toLowerCase().includes(query) || item.displayName.toLowerCase().includes(query)).slice(0, 60),
  })), [catalog, connected, typed, query]);
  const choices = groups.flatMap((group) => group.models.map((item) => ({ connection: group.id, item })));
  const shown = open && (groups.length > 0 || !!onConnectMore);
  const offline = !connected.has(connection);
  const pick = (next: { connection: ConnectionId; item: AvailableModel }) => { onChange({ connection: next.connection, model: next.item.id }); setOpen(false); setActive(-1); };

  return <div className={`connection-picker${offline ? " offline" : ""}`}>
    <button type="button" className={`connection-pill ${connection}`} tabIndex={-1} aria-label={`${label}: ${connectionInfo[connection].name}${offline ? ", not connected" : ""}. Change`}
      title={offline ? `${connectionInfo[connection].name} is not connected` : `${connectionInfo[connection].name} · billed ${connectionInfo[connection].billing === "Plan" ? "to your plan" : "per token"}`}
      onMouseDown={(event) => { event.preventDefault(); setOpen(!open); }}>
      <i aria-hidden="true" />{connectionInfo[connection].short}
    </button>
    <input role="combobox" aria-label={label} aria-invalid={invalid} aria-expanded={shown} aria-controls={menu} aria-autocomplete="list"
      aria-activedescendant={shown && active >= 0 ? `${menu}-${active}` : undefined}
      autoComplete="off" spellCheck={false} placeholder={placeholder} value={model}
      onChange={(event) => { onChange({ connection, model: event.target.value }); setOpen(true); setTyped(true); setActive(-1); }}
      onClick={() => { if (!open) setTyped(false); setOpen(true); }} onBlur={() => { setOpen(false); setActive(-1); }}
      onKeyDown={(event) => {
        if (event.key === "ArrowDown" || event.key === "ArrowUp") {
          event.preventDefault();
          if (!shown) { setOpen(true); return; }
          if (choices.length) setActive((current) => (current + (event.key === "ArrowDown" ? 1 : choices.length - (current < 0 ? 0 : 1))) % choices.length);
        } else if (event.key === "Enter" && shown && choices[active]) { event.preventDefault(); pick(choices[active]); }
        else if (event.key === "Escape" && shown) { event.stopPropagation(); setOpen(false); setActive(-1); }
      }} />
    {shown && <div id={menu} className="connection-menu" role="listbox" aria-label={`${label} suggestions`}>
      {groups.map((group) => {
        const offset = choices.findIndex((choice) => choice.connection === group.id);
        return <div key={group.id} role="group" aria-label={connectionInfo[group.id].name} className="connection-group">
          <div className="connection-group-title"><span className={`connection-dot ${group.id}`} aria-hidden="true" /><strong>{connectionInfo[group.id].name}</strong>
            <em className={`billing ${connectionInfo[group.id].billing.toLowerCase()}`}>{connectionInfo[group.id].billing}</em></div>
          {group.id !== connection && model.trim() && !group.models.some((item) => item.id === model) && <button type="button" className="connection-use" onMouseDown={(event) => { event.preventDefault(); onChange({ connection: group.id, model }); setOpen(false); }}>
            Use {model.trim() ? <code>{model}</code> : "a typed model ID"} with {connectionInfo[group.id].short}</button>}
          {group.models.map((item, index) => {
            const position = offset + index;
            return <div key={item.id} id={`${menu}-${position}`} role="option" aria-selected={group.id === connection && item.id === model}
              className={`model-option${active === position ? " active" : ""}`} onMouseDown={(event) => { event.preventDefault(); pick({ connection: group.id, item }); }}>
              {item.displayName && item.displayName !== item.id ? <><span>{item.displayName}</span><code>{item.id}</code></> : <code>{item.id}</code>}
            </div>;
          })}
        </div>;
      })}
      {groups.every((group) => group.id !== connection) && <p className="connection-empty">Connect a provider to see its models.</p>}
      {onConnectMore && <button type="button" className="connection-more" onMouseDown={(event) => { event.preventDefault(); setOpen(false); onConnectMore(); }}>+ Connect another provider</button>}
    </div>}
  </div>;
}
