import { useEffect, useMemo, useRef, useState, type CSSProperties, type KeyboardEvent } from "react";
import { api, native, type RouteSettings } from "./api";
import {
  activeSessionIDs, callCost, compact, dollars, group, judgeColor, modelIDs as stableModelIDs, parseRecords, priceFor, profile as routingProfile, roleFor,
  sessions as deriveSessions, standardTime, tint, type LogRecord, type PriceTable, type Profile, type Session,
} from "./activityModel";

/** One routed call, with the judge calls that picked its model folded under it. */
interface Entry { key: string; record: LogRecord; judges: LogRecord[]; chose?: LogRecord }
type Kind = "all" | "routed" | "judge";
const ranges = [["all", "Whole log"], ["15", "15 min"], ["60", "1 hour"], ["360", "6 hours"], ["1440", "24 hours"]] as const;
const kinds: [Kind, string][] = [["all", "All"], ["routed", "Routed"], ["judge", "Judge"]];

const rawString = (record: LogRecord, key: string) => { const value = record.raw[key]; return typeof value === "string" && value.trim() ? value : null; };
const keyOf = (record: LogRecord) => [record.ts ?? "", rawString(record, "turn_id") ?? "", record.modelIdentity, record.tier ?? "", record.tokens.total].join("|");

/** Judge calls precede the call they routed; pair them oldest-first within a turn. */
function entries(records: LogRecord[]): Entry[] {
  const pending = new Map<string, LogRecord[]>();
  const out: Entry[] = [];
  const seen = new Map<string, number>();
  const unique = (record: LogRecord) => { const base = keyOf(record); const n = seen.get(base) ?? 0; seen.set(base, n + 1); return n ? `${base}#${n}` : base; };
  for (const record of [...records].reverse()) {
    const turn = `${record.sessionID ?? ""}|${rawString(record, "turn_id") ?? ""}`;
    if (record.isClassifier) { pending.set(turn, [...(pending.get(turn) ?? []), record]); continue; }
    out.push({ key: unique(record), record, judges: pending.get(turn) ?? [] });
    pending.delete(turn);
  }
  for (const judges of pending.values()) for (const judge of judges) out.push({ key: unique(judge), record: judge, judges: [] });
  return out.sort((a, b) => (b.record.ts ?? 0) - (a.record.ts ?? 0) || b.record.id - a.record.id);
}

function dayLabel(ms: number, now: number): string {
  const day = (value: number) => { const date = new Date(value); date.setHours(0, 0, 0, 0); return date.getTime(); };
  const diff = Math.round((day(now) - day(ms)) / 86_400_000);
  if (diff === 0) return "Today";
  if (diff === 1) return "Yesterday";
  return new Date(ms).toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" });
}

function matches(entry: Entry, query: string, profile: Profile): boolean {
  if (!query) return true;
  const { record } = entry;
  const haystack = [record.modelIdentity, roleFor(record, profile), record.origin, record.sessionID, record.agentID, rawString(record, "turn_id"), rawString(record, "reasoning_effort"), ...entry.judges.map((judge) => judge.modelIdentity)];
  return haystack.some((value) => value?.toLowerCase().includes(query));
}

export function RequestHistory({ running, settings }: { running: boolean; settings: RouteSettings }) {
  const [rows, setRows] = useState<Record<string, unknown>[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState("");
  const [search, setSearch] = useState("");
  const [range, setRange] = useState("all");
  const [kind, setKind] = useState<Kind>("all");
  const [sessionID, setSessionID] = useState("");
  const [selectedKey, setSelectedKey] = useState<string | null>(null);
  const [prices, setPrices] = useState<PriceTable | null>(null);
  const [fresh, setFresh] = useState<Set<string>>(() => new Set());
  const [refreshedAt, setRefreshedAt] = useState(() => Date.now());
  const known = useRef<Set<string> | null>(null);
  const list = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!native) return;
    let active = true;
    api.modelPrices().then((table) => { if (active) setPrices(table); }).catch(() => undefined);
    return () => { active = false; };
  }, []);

  useEffect(() => {
    if (!native) return;
    let active = true;
    let timer: ReturnType<typeof setTimeout>;
    async function poll() {
      try {
        const next = await api.history();
        if (active) { setRows(next); setError(""); }
      } catch (reason) { if (active) setError(String(reason)); }
      if (active) { setLoaded(true); setRefreshedAt(Date.now()); }
      if (active && running) timer = setTimeout(poll, 2000);
    }
    void poll();
    return () => { active = false; clearTimeout(timer); };
  }, [running]);

  const records = useMemo(() => parseRecords(rows), [rows]);
  const profile = useMemo(() => routingProfile(settings), [settings]);
  const all = useMemo(() => entries(records), [records]);
  const sessions = useMemo(() => deriveSessions(records), [records]);
  const live = useMemo(() => activeSessionIDs(records, refreshedAt), [records, refreshedAt]);
  const modelIDs = useMemo(() => stableModelIDs(profile, records, refreshedAt), [profile, records, refreshedAt]);
  const session = sessions.find((item) => item.id === sessionID) ?? null;

  // Rows that arrive after the first load slide in; the initial page does not animate row by row.
  useEffect(() => {
    if (!loaded) return;
    const keys = new Set(all.map((entry) => entry.key));
    const previous = known.current;
    known.current = keys;
    setFresh(previous ? new Set([...keys].filter((key) => !previous.has(key))) : new Set());
  }, [all, loaded]);

  const query = search.trim().toLowerCase();
  const since = range === "all" ? null : refreshedAt - Number(range) * 60_000;
  const scoped = all.filter((entry) => (!session || entry.record.sessionID === session.id) && (since == null || (entry.record.ts != null && entry.record.ts >= since)));
  const byKind = kind === "all" ? scoped : kind === "routed" ? scoped.filter((entry) => !entry.record.isClassifier)
    : scoped.flatMap((entry) => entry.record.isClassifier ? [entry] : entry.judges.map((judge, index) => ({ key: `${entry.key}~${index}`, record: judge, judges: [], chose: entry.record })));
  const visible = byKind.filter((entry) => matches(entry, query, profile));
  const selected = visible.find((entry) => entry.key === selectedKey) ?? visible[0] ?? null;
  const counted = scoped.filter((entry) => matches(entry, query, profile));
  const routedCount = counted.filter((entry) => !entry.record.isClassifier).length;
  const judgeCount = counted.reduce((sum, entry) => sum + (entry.record.isClassifier ? 1 : entry.judges.length), 0);
  const filtered = !!query || range !== "all" || kind !== "all" || !!session;
  const scopeName = session ? session.title : range === "all" ? "the log tail" : `the last ${ranges.find(([value]) => value === range)![1]}`;
  const maxPrompt = Math.max(1, ...visible.map((entry) => entry.record.tokens.prompt));

  function move(event: KeyboardEvent<HTMLDivElement>) {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    event.preventDefault();
    const index = selected ? visible.indexOf(selected) : -1;
    const next = visible[Math.min(Math.max(index + (event.key === "ArrowDown" ? 1 : -1), 0), visible.length - 1)];
    if (!next) return;
    setSelectedKey(next.key);
    list.current?.querySelector<HTMLElement>(`[data-key="${CSS.escape(next.key)}"]`)?.scrollIntoView({ block: "nearest" });
  }
  const clear = () => { setSearch(""); setRange("all"); setKind("all"); setSessionID(""); };
  const emptyReason = !native ? "The routing log is read by the desktop app. This browser preview shows layout only."
    : !loaded ? "Reading the routing log…"
    : records.length ? null
    : running ? "No routed turns yet. The log fills as Codex sends requests through the proxy." : "Routing is off. Start routing, then send a Codex request.";

  let lastDay = "";
  return <div className="activity requests" key="requests">
    <header className="req-head">
      <div className="req-title"><h1>Requests</h1>
        <span>{emptyReason ? "Routing log" : <>{kind !== "all" && <>Showing {kind === "judge" ? "judge calls" : "routed calls"} · </>}<b>{group(routedCount)}</b> routed · <b>{group(judgeCount)}</b> judge in {scopeName}</>}</span></div>
      <div className="req-filters">
        <label className="req-select" title="Show one Codex conversation's turns">
          {session && live.has(session.id) && <i className="session-live" aria-hidden="true" />}
          <select aria-label="Session" value={sessionID} onChange={(event) => setSessionID(event.target.value)} disabled={!sessions.length}>
            <option value="">All sessions</option>
            {sessions.map((item) => <option key={item.id} value={item.id}>{live.has(item.id) ? "● " : ""}{item.title} — {item.detail}</option>)}
          </select>
        </label>
        <div className="req-segments" role="radiogroup" aria-label="Call kind">
          {kinds.map(([value, label]) => <button key={value} role="radio" aria-checked={kind === value} className={kind === value ? "on" : ""} onClick={() => setKind(value)}>{label}</button>)}
        </div>
        <label className="req-select"><select aria-label="Time range" value={range} onChange={(event) => setRange(event.target.value)}>
          {ranges.map(([value, label]) => <option key={value} value={value}>{label}</option>)}
        </select></label>
        <label className="req-search"><span aria-hidden="true">⌕</span><input aria-label="Search requests" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Model, role, session, agent" /></label>
      </div>
    </header>

    {error && <div className="banner error" role="alert">Routing log unavailable: {error}</div>}

    {emptyReason ? <section className="signal-box"><div className="act-empty"><span aria-hidden="true">≡</span><p>{emptyReason}</p></div></section>
      : <div className="req-body">
        <section className="signal-box req-log" aria-label="Routed calls">
          <div className="req-cols" aria-hidden="true"><span>Time</span><span>Role · model</span><span className="req-legend-head">Prompt <i className="fresh" />fresh <i className="cached" />cached</span><span>Output</span></div>
          {visible.length === 0 ? <div className="act-empty"><span aria-hidden="true">⌕</span><p>No calls match this filter in {scopeName}.</p>{filtered && <button className="card-link" onClick={clear}>Clear filters</button>}</div>
            : <div className="req-rows" role="listbox" aria-label="Calls, newest first" tabIndex={0} ref={list} onKeyDown={move} aria-activedescendant={selected ? `req-${selected.record.id}` : undefined}>
              {visible.map((entry) => {
                const day = entry.record.ts == null ? "Undated" : dayLabel(entry.record.ts, refreshedAt);
                const divider = day !== lastDay ? <div className="req-day" key={`day-${day}`}>{day}</div> : null;
                lastDay = day;
                return [divider, <Row key={entry.key} entry={entry} profile={profile} modelIDs={modelIDs} maxPrompt={maxPrompt} selected={entry === selected} fresh={fresh.has(entry.key)} onSelect={() => { setSelectedKey(entry.key); if (window.matchMedia?.("(max-width: 760px)").matches) requestAnimationFrame(() => document.querySelector(".req-inspector")?.scrollIntoView({ behavior: "smooth", block: "start" })); }} />];
              })}
            </div>}
        </section>
        {selected ? <Inspector key={selected.key} entry={selected} profile={profile} modelIDs={modelIDs} prices={prices} session={sessions.find((item) => item.id === selected.record.sessionID) ?? null} />
          : <aside className="signal-box req-inspector"><div className="act-empty"><p>Select a call to see its full log record.</p></div></aside>}
      </div>}
  </div>;
}

function Row({ entry, profile, modelIDs, maxPrompt, selected, fresh, onSelect }: { entry: Entry; profile: Profile; modelIDs: string[]; maxPrompt: number; selected: boolean; fresh: boolean; onSelect: () => void }) {
  const { record, judges } = entry;
  const color = record.isClassifier ? judgeColor : tint(record.modelIdentity, modelIDs);
  const { prompt, cached, completion } = record.tokens;
  const width = prompt / maxPrompt * 100;
  const effort = rawString(record, "reasoning_effort");
  return <div id={`req-${record.id}`} data-key={entry.key} role="option" aria-selected={selected} onClick={onSelect}
    className={`req-row${record.isClassifier ? " judge" : ""}${selected ? " selected" : ""}${fresh ? " fresh" : ""}`} style={{ "--tint": color } as CSSProperties}>
    <code className="req-time">{record.ts == null ? "—" : standardTime(record.ts)}</code>
    <span className="req-who">
      <span className="req-role"><i aria-hidden="true" />{record.isClassifier ? "Judge" : roleFor(record, profile) ?? "Unassigned"}{record.isDelegated && <em>delegated</em>}</span>
      <code className="req-model">{record.modelIdentity}{effort && <span> · {effort}</span>}</code>
      {judges.map((judge) => <code key={judge.id} className="req-judge" title={`Judge call (${judge.modelIdentity}) that chose this model`}>↳ judge{judge.modelIdentity !== profile.classifierModelID ? ` · ${judge.modelIdentity}` : ""} · {compact(judge.tokens.total)}</code>)}
      {entry.chose && <code className="req-judge" title="The call this judge routed">→ {roleFor(entry.chose, profile) ?? "Unassigned"} · {entry.chose.modelIdentity}</code>}
    </span>
    <span className="req-tokens" title={`${group(prompt)} prompt tokens, ${group(cached)} from cache`}>
      <span className="req-bar"><i style={{ width: `${width}%` }}><b style={{ width: `${prompt ? Math.max(1 - cached / prompt, 0) * 100 : 0}%` }} /></i></span>
      <code>{prompt ? compact(prompt) : "—"}{prompt > 0 && cached > 0 && <span> · {Math.floor(cached / prompt * 100)}% cache</span>}</code>
    </span>
    <code className="req-out">{completion ? compact(completion) : "—"}</code>
  </div>;
}

const shortID = (id: string | null) => id ? (id.length > 14 ? `…${id.slice(-8)}` : id) : null;

function Inspector({ entry, profile, modelIDs, prices, session }: { entry: Entry; profile: Profile; modelIDs: string[]; prices: PriceTable | null; session: Session | null }) {
  const { record, judges } = entry;
  const [copied, setCopied] = useState(false);
  const color = record.isClassifier ? judgeColor : tint(record.modelIdentity, modelIDs);
  const t = record.tokens;
  const costs = prices ? priceFor(record.modelIdentity, prices) : null;
  const judgeCost = prices ? judges.reduce((sum, judge) => { const table = priceFor(judge.modelIdentity, prices); return table ? sum + callCost(judge.tokens, table) : sum; }, 0) : 0;
  const fields = Object.entries(record.raw).sort(([a], [b]) => a.localeCompare(b));
  const facts: [string, string | null, string?][] = [
    ["Session", session ? session.title : shortID(record.sessionID), record.sessionID ?? undefined],
    ["Turn", shortID(rawString(record, "turn_id")), rawString(record, "turn_id") ?? undefined],
    ["Agent", record.agentID && record.agentID !== record.sessionID ? shortID(record.agentID) : record.agentID ? "main thread" : null, record.agentID ?? undefined],
    ["Origin", record.origin],
    ["Route", record.route],
    ["Algorithm", rawString(record, "algorithm")],
    ["Effort", rawString(record, "reasoning_effort")],
  ];
  const segments = [["Fresh prompt", Math.max(t.prompt - t.cached, 0), 1], ["Cached", t.cached, 0.3], ["Output", Math.max(t.completion - t.reasoning, 0), 0.75], ["Reasoning", t.reasoning, 0.55]] as const;
  const sum = Math.max(1, segments.reduce((total, [, value]) => total + value, 0));
  async function copy() {
    try { await navigator.clipboard.writeText(JSON.stringify(record.raw, null, 2)); setCopied(true); setTimeout(() => setCopied(false), 1500); } catch { /* clipboard denied: nothing to report */ }
  }
  return <aside className="signal-box req-inspector" aria-label="Selected call" style={{ "--tint": color } as CSSProperties}>
    <header className="req-ins-head">
      <span className="req-kind">{record.isClassifier ? "Judge call" : "Routed call"}</span>
      <code>{record.ts == null ? "—" : `${new Date(record.ts).toLocaleDateString("en-US", { month: "short", day: "numeric" })} · ${standardTime(record.ts)}`}</code>
    </header>
    <div className="req-ins-hero">
      <span className="req-role"><i aria-hidden="true" />{record.isClassifier ? "Judge" : roleFor(record, profile) ?? "Unassigned"}</span>
      <code>{record.modelIdentity}</code>
      {costs && <small>≈ {dollars(callCost(t, costs))} at list price{judgeCost > 0 ? ` · judge ${dollars(judgeCost)}` : ""}</small>}
    </div>
    <div className="req-ins-tokens">
      <div className="req-ins-total"><strong>{group(t.total)}</strong><span>tokens</span></div>
      <div className="req-stack" aria-hidden="true">{segments.map(([label, value, alpha]) => value > 0 && <i key={label} style={{ width: `${value / sum * 100}%`, opacity: alpha }} />)}</div>
      <dl className="req-legend">{segments.map(([label, value, alpha]) => <div key={label}><dt><i style={{ opacity: alpha }} />{label}</dt><dd>{value ? group(value) : "—"}</dd></div>)}</dl>
    </div>
    {judges.length > 0 && <div className="req-ins-judges"><h4>Chosen by</h4>{judges.map((judge) => <div key={judge.id}><i aria-hidden="true" /><code>{judge.modelIdentity}</code><span>{group(judge.tokens.total)} tok</span></div>)}</div>}
    <dl className="req-facts">{facts.filter(([, value]) => value).map(([label, value, full]) => <div key={label}><dt>{label}</dt><dd title={full}>{value}</dd></div>)}</dl>
    <details className="req-raw">
      <summary>Full log record <span>· {fields.length} fields</span></summary>
      <dl>{fields.map(([key, value]) => <div key={key}><dt>{key}</dt><dd className={value == null ? "null" : undefined}>{value == null ? "null" : typeof value === "string" ? value : JSON.stringify(value)}</dd></div>)}</dl>
      <button className="card-link" onClick={() => void copy()}>{copied ? "Copied" : "Copy JSON"}</button>
    </details>
    <p className="req-note">Only what Switchyard logged: model and token usage. Latency and errors are on Activity.</p>
  </aside>;
}
