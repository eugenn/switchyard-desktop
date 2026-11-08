import { useEffect, useMemo, useState, type ReactNode } from "react";
import { api, native, type RouteSettings } from "./api";
import {
  activeSessionIDs, compact, dollars, droppingHousekeepingThreads, estimateCost, compactShort, computeMetrics, contextUsage, durationText, group, judgeColor, lanes as orderLanes, milliseconds, modelIDs as stableModelIDs,
  parseRecords, parseStats, percent, profile as routingProfile, rate, roleFor, seconds, sessionSpan, sessions as deriveSessions, shortTime, standardTime, ticks as deriveTicks, tint,
  type ContextUsage, type CostEstimate, type FlowRole, type PriceTable, type LogRecord, type Metrics, type Session, type ServerStats, type Share, type Tick,
} from "./activityModel";

const SOURCE = 164, RAIL = 76, LABEL = 214, CONTEXT = 108, LANE = 58, GAP = 8, NODE = 74, MIN_BODY = 214;

type Props = { settings: RouteSettings; stats: unknown; statsError: string; running: boolean; onOpenRequests: () => void; onConfigure: () => void };

export function Activity({ settings, stats: rawStats, statsError, running, onOpenRequests, onConfigure }: Props) {
  const [rows, setRows] = useState<Record<string, unknown>[]>([]);
  const [historyError, setHistoryError] = useState("");
  const [lastRefresh, setLastRefresh] = useState<number | null>(null);
  const [selectedModelID, setSelectedModelID] = useState<string | null>(null);
  const [selectedSessionID, setSelectedSessionID] = useState<string | null>(null);
  const [prices, setPrices] = useState<PriceTable | null>(null);
  const [pricesError, setPricesError] = useState("");

  useEffect(() => {
    if (!native) return;
    let active = true;
    let timer: ReturnType<typeof setTimeout>;
    async function refresh() {
      try {
        const table = await api.modelPrices(true);
        if (active) { setPrices(table); setPricesError(""); }
      } catch (reason) { if (active) setPricesError(String(reason)); }
      if (active) timer = setTimeout(refresh, 60 * 60_000);
    }
    void api.modelPrices().then((table) => { if (active) setPrices(table); })
      .catch((reason: unknown) => { if (active) setPricesError(String(reason)); })
      .finally(() => { if (active) void refresh(); });
    return () => { active = false; clearTimeout(timer); };
  }, []);

  useEffect(() => {
    if (!native) return;
    let active = true;
    let timer: ReturnType<typeof setTimeout>;
    async function poll() {
      try {
        const next = await api.history();
        const parsed = parseRecords(next);
        const ids = [...new Set(parsed.filter((record) => record.origin === "codex-cli" && record.sessionID).map((record) => record.sessionID!))];
        let visible = parsed;
        if (ids.length) {
          try { visible = droppingHousekeepingThreads(parsed, new Set(await api.rolloutSessionIDs(ids))); }
          catch { visible = parsed; }
        }
        if (active) { setRows(visible.map((record) => record.raw)); setHistoryError(""); }
      }
      catch (reason) { if (active) setHistoryError(String(reason)); }
      if (active) setLastRefresh(Date.now());
      if (active && running) timer = setTimeout(poll, 3000);
    }
    void poll();
    return () => { active = false; clearTimeout(timer); };
  }, [running]);

  const now = lastRefresh ?? Date.now();
  const records = useMemo(() => parseRecords(rows), [rows]);
  const stats = useMemo(() => rawStats ? parseStats(rawStats) : null, [rawStats]);
  const profile = useMemo(() => routingProfile(settings), [settings]);
  const sessions = useMemo(() => deriveSessions(records), [records]);
  const active = useMemo(() => activeSessionIDs(records, now), [records, now]);
  const flowSession = sessions.find((session) => session.id === selectedSessionID) ?? sessions[0] ?? null;
  const scoped = flowSession ? records.filter((record) => record.sessionID === flowSession.id) : records;
  const metrics = computeMetrics(scoped, now, sessionSpan(flowSession), profile.assignments);
  const modelIDs = stableModelIDs(profile, records, now);
  // Judge calls count toward spend; without a session, the last 15 minutes (timestamp-less rows included).
  const costRecords = flowSession ? scoped : records.filter((record) => record.ts == null || record.ts >= now - 15 * 60_000);
  const judgeModel = settings.judgeModel?.trim();
  const aliases: Record<string, string> = judgeModel ? { [`judge-${judgeModel}`]: judgeModel } : {};
  const cost = prices ? estimateCost(costRecords, prices, aliases) : null;
  const emptyReason = records.length ? null : !running ? "Routing is off. Start routing, then send a Codex request." : "No routed turns yet. The log fills as Codex sends requests through the proxy.";

  return <div className="activity" key="activity">
    {(statsError || historyError) && <div className="banner error" role="alert">{statsError ? `Statistics unavailable: ${statsError}` : `Routing log unavailable: ${historyError}`}</div>}
    <Summary metrics={metrics} stats={stats} session={flowSession} lastRefresh={lastRefresh} cost={cost} pricesError={pricesError} />
    <SignalBox metrics={metrics} modelIDs={modelIDs} isRouting={running} asOf={lastRefresh} usesClassifier={profile.usesClassifier} classifierModelID={profile.classifierModelID}
      roles={profile.roles} ticks={deriveTicks(records, flowSession?.id ?? null, metrics.windowStart, metrics.windowEnd)}
      context={flowSession ? contextUsage(records, flowSession.id, settings.contextWindow ?? null) : null} session={flowSession} sessions={sessions} active={active}
      selectedModelID={selectedModelID} onSelectModel={setSelectedModelID} onSelectSession={setSelectedSessionID} onConfigure={onConfigure} />
    <div className="activity-pair">
      <LatencyCard stats={stats} modelIDs={modelIDs} selectedModelID={selectedModelID} onShowAll={() => setSelectedModelID(null)} />
      <LatestTurns records={records} session={flowSession} modelIDs={modelIDs} roleOf={(record) => roleFor(record, profile)} emptyReason={emptyReason} onOpenRequests={onOpenRequests} />
    </div>
    <div className="stats-pair">
      <ModelsAndProxy metrics={metrics} stats={stats} session={flowSession} roleName={(target) => target == null ? null : profile.targetNames.get(target) ?? target} />
      {(metrics.delegatedCount > 0 || metrics.subagentIdentityUnsupported) && <Subagents metrics={metrics} modelIDs={modelIDs} />}
    </div>
  </div>;
}

// ---------- summary ----------

function Stat({ value, unit, label, tone, title }: { value: string; unit?: string; label: ReactNode; tone?: string; title?: string }) {
  return <div className="act-stat" title={title}><strong style={tone ? { color: tone } : undefined}>{value}{unit && <small>{unit}</small>}</strong><span>{label}</span></div>;
}

function Summary({ metrics, stats, session, lastRefresh, cost, pricesError }: { metrics: Metrics; stats: ServerStats | null; session: Session | null; lastRefresh: number | null; cost: CostEstimate | null; pricesError: string }) {
  const errors = stats?.totalErrors;
  const warning = stats && stats.classifierErrors > 0 ? `${stats.classifierErrors} of ${stats.classifierRequests} classifier calls failed` : stats?.fallbacks[0] ? `fallback: ${stats.fallbacks[0][0]}` : null;
  const scope = session ? "this session" : "the last 15 minutes";
  const started = session?.startedAt ?? null;
  return <section className="act-summary" aria-label="Summary">
    <Stat value={group(metrics.count)} label={metrics.count === 1 ? "request routed" : "requests routed"}
      title={metrics.secondsPerRequest == null ? `Turns routed in ${scope}.` : `Turns routed in ${scope}, one every ${metrics.secondsPerRequest.toFixed(1)} s.`} />
    <Stat value={errors == null ? "—" : String(errors)} tone={(errors ?? 0) > 0 ? "var(--crit)" : undefined} title="Errors the proxy returned since switchyard-server started."
      label={warning ? <em className="warn-text">{warning}</em> : errors == null ? "model errors" : <><i className="act-dot" style={{ background: errors > 0 ? "var(--crit)" : "var(--accent)" }} />{errors === 1 ? "model error" : "model errors"}</>} />
    <Stat value={compact(metrics.tokens)} label={metrics.count > 0 ? `tokens · ${compactShort(Math.floor(metrics.tokens / metrics.count))} per turn` : "tokens"} />
    <Stat value={metrics.tokens > 0 ? percent(metrics.cachedTokens / metrics.tokens) : "—"} unit={metrics.tokens > 0 ? "%" : undefined} label="served from cache"
      title={metrics.cachedTokens > 0 ? `${group(metrics.cachedTokens)} of ${group(metrics.tokens)} prompt tokens were cache hits.` : "No cache hits in this window."} />
    <CostStat cost={cost} session={session} pricesError={pricesError} />
    <div className="act-scope"><strong>{session ? "This session" : "Last 15 minutes"}</strong>
      <span>{started != null && lastRefresh != null ? `since ${shortTime(started)} · updated ${standardTime(lastRefresh)}` : lastRefresh != null ? `updated ${standardTime(lastRefresh)}` : started != null ? `since ${shortTime(started)}` : "waiting for the first read"}</span></div>
  </section>;
}

/** Approximate spend at API list prices. Tokens on a model the map has no price for are named, not guessed. */
function CostStat({ cost, session, pricesError }: { cost: CostEstimate | null; session: Session | null; pricesError: string }) {
  if (!cost) return <Stat value="—" label={pricesError ? "no price map" : "reading prices…"} title={pricesError || "Loading LiteLLM's cached or bundled price map and checking for updates."} />;
  const priced = cost.pricedCalls > 0;
  const unpriced = cost.unpricedModels[0] && (cost.unpricedModels.length === 1 ? cost.unpricedModels[0] : `${cost.unpricedModels[0]} +${cost.unpricedModels.length - 1}`);
  const label = cost.pricedCalls + cost.unpricedCalls === 0 ? "no calls to price" : unpriced ? <>{priced ? "est. · excl. " : "no list price for "}<em className="warn-text">{unpriced}</em></> : "est. at API list price";
  const lines = [`${session ? `${session.title}, judge calls included` : "The last 15 minutes of traffic"}, priced the way LiteLLM prices a call, from LiteLLM's price map (updated daily, with a cached or bundled fallback offline). A ChatGPT plan is not billed per token, so this is the equivalent API spend.`];
  if (priced && cost.uncachedDollars > cost.dollars) lines.push(`Cache hits saved about ${dollars(cost.uncachedDollars - cost.dollars)}.`);
  if (cost.unpricedModels.length) lines.push(`Not included: ${cost.unpricedCalls} calls, ${compact(cost.unpricedTokens)} tokens on ${cost.unpricedModels.join(", ")}, which LiteLLM has no price for.`);
  return <Stat value={priced ? dollars(cost.dollars) : "—"} label={label} title={lines.join("\n")} />;
}

// ---------- where requests go ----------

type SignalProps = {
  metrics: Metrics; modelIDs: string[]; isRouting: boolean; asOf: number | null; usesClassifier: boolean; classifierModelID: string | null; roles: Map<string, FlowRole>;
  ticks: Map<string, Tick[]>; context: Map<string, ContextUsage> | null; session: Session | null; sessions: Session[]; active: Set<string>;
  selectedModelID: string | null; onSelectModel: (id: string | null) => void; onSelectSession: (id: string) => void; onConfigure: () => void;
};

function SignalBox(props: SignalProps) {
  const { metrics, modelIDs, isRouting, asOf, roles, session, selectedModelID } = props;
  const lanes = orderLanes(metrics, roles);
  const showsClassifier = props.usesClassifier || metrics.classifierShares.length > 0;
  const latest = metrics.latest;
  const sinceLatest = latest?.at != null ? ((asOf ?? metrics.windowEnd) - latest.at) / 1000 : null;
  const isLive = isRouting && latest != null && (sinceLatest ?? 0) <= 8;
  const isThinking = isRouting && !isLive && sinceLatest != null && sinceLatest <= 600;
  const latestModelID = latest && !latest.isClassifier ? latest.modelID : null;
  const span = session && session.startedAt != null && session.lastActivity != null ? (session.lastActivity - session.startedAt) / 1000 : null;
  const windowLabel = !session ? "Last 15 minutes" : span == null || span < 1 ? "One session" : `This session · ${durationText(span)}`;
  const lanesHeight = lanes.length * LANE + Math.max(lanes.length - 1, 0) * GAP;
  const body = Math.max(MIN_BODY, lanesHeight + 24);
  const center = body / 2;
  const laneCenter = (index: number) => (body - lanesHeight) / 2 + index * (LANE + GAP) + LANE / 2;
  const path = (index: number) => { const end = laneCenter(index); return `M0 ${center} C${RAIL * 0.55} ${center} ${RAIL * 0.45} ${end} ${RAIL} ${end}`; };
  const latestIndex = lanes.findIndex((lane) => lane.id === latestModelID);
  const reducedMotion = typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;
  const showsContext = props.context != null;
  const liveTint = latest?.isClassifier ? judgeColor : latest ? tint(latest.modelID, modelIDs) : "var(--ink3)";
  const cadence = (() => {
    const count = metrics.classifierCount;
    if (count <= 1) return `${count} call`;
    const every = Math.round(metrics.windowDuration / count);
    return every > 0 ? `${group(count)} calls · 1 per ${durationText(every)}` : `${count} calls`;
  })();

  return <section className="signal-box" aria-label="Where requests go">
    <header className="signal-head">
      <h2>Where requests go</h2><span className="signal-window">{windowLabel}</span><span className="spacer" />
      {latest && (isLive || isThinking) && <span className="live-badge" style={{ ["--tint" as string]: isLive ? liveTint : "var(--ink3)" }}>
        <i className={isLive ? "blink" : ""} />{isLive ? (latest.isClassifier ? "classifier" : roles.get(latest.modelID)?.name ?? latest.modelID) : "waiting"}</span>}
      {(props.sessions.length > 0 || isRouting) && <SessionPicker sessions={props.sessions} session={session} active={props.active} onSelect={props.onSelectSession} />}
    </header>
    {metrics.subagentIdentityUnsupported && <p className="identity-warning"><span aria-hidden="true">▲</span>Harness does not send subagent identity; delegated requests route through parent.</p>}
    {lanes.length === 0 ? <div className="act-empty"><span aria-hidden="true">⌁</span><p>{session ? "This session routed no turns the log could attribute to a model." : "Assign models in Routing config to see where requests go."}</p>
      {!session && <button className="button secondary" onClick={props.onConfigure}>Open routing config</button>}</div> : <>
      <div className="signal-map" style={{ height: body }}>
        <div className="signal-source" style={{ width: SOURCE }}>
          {showsClassifier && <><div className="client-label" style={{ top: center - NODE / 2 - 44 }}><code>codex</code><span>local client</span></div>
            <i className="client-connector" style={{ top: center - NODE / 2 - 19 }} /></>}
          <div className={`source-node${latest?.isClassifier && isLive ? " judging" : ""}`} style={{ top: center - NODE / 2 }}>
            <strong><span aria-hidden="true">{showsClassifier ? "✦" : "⑂"}</span>{showsClassifier ? "Classifier" : "Switchyard"}</strong>
            {showsClassifier ? <><code title={metrics.classifierShares[0]?.id ?? props.classifierModelID ?? "not assigned"}>{metrics.classifierShares[0]?.id ?? props.classifierModelID ?? "not assigned"}</code><small>{cadence}</small></>
              : <small>{group(metrics.count)} turns routed</small>}
          </div>
        </div>
        <svg className="signal-rails" width={RAIL} height={body} aria-hidden="true">
          {lanes.map((lane, index) => {
            const dimmed = selectedModelID != null && selectedModelID !== lane.id;
            const isLatest = lane.id === latestModelID;
            const width = lane.count === 0 ? 1 : Math.max(1.5, Math.sqrt(lane.share) * 9);
            return <path key={lane.id} d={path(index)} fill="none" stroke={tint(lane.id, modelIDs)} strokeWidth={width} strokeLinecap="round"
              strokeOpacity={dimmed ? 0.14 : isLatest ? 0.9 : lane.count === 0 ? 0.2 : 0.4} />;
          })}
          {isLive && latestIndex >= 0 && !reducedMotion && <circle r={3} fill="#E9FFF2"><animateMotion dur="1.6s" repeatCount="indefinite" calcMode="spline" keyPoints="0;1" keyTimes="0;1" keySplines="0.65 0 0.35 1" path={path(latestIndex)} /></circle>}
          <circle cx={0} cy={center} r={3.5} fill="var(--accent)" />
        </svg>
        <div className="signal-lanes">
          {lanes.map((lane) => <Lane key={lane.id} lane={lane} modelIDs={modelIDs} role={roles.get(lane.id)} ticks={props.ticks.get(lane.id) ?? []}
            context={showsContext ? props.context!.get(lane.id) ?? null : undefined} isLatest={lane.id === latestModelID} isLive={isLive} pulses={(isLive || isThinking) && !reducedMotion}
            selected={selectedModelID === lane.id} dimmed={selectedModelID != null && selectedModelID !== lane.id}
            onToggle={() => props.onSelectModel(selectedModelID === lane.id ? null : lane.id)} />)}
        </div>
      </div>
      <div className="signal-axis" style={{ paddingLeft: 16 + SOURCE + RAIL + LABEL + 4, paddingRight: 14 + 18 + (showsContext ? CONTEXT + 12 : 0) }}>
        <span>{shortTime(metrics.windowStart)}</span><span className="caption">each tick is one turn · taller means more tokens</span><span>{isRouting ? "now" : shortTime(metrics.windowEnd)}</span>
      </div>
    </>}
  </section>;
}

function Lane({ lane, modelIDs, role, ticks, context, isLatest, isLive, pulses, selected, dimmed, onToggle }: {
  lane: Share; modelIDs: string[]; role: FlowRole | undefined; ticks: Tick[]; context: ContextUsage | null | undefined; isLatest: boolean; isLive: boolean; pulses: boolean;
  selected: boolean; dimmed: boolean; onToggle: () => void;
}) {
  const color = tint(lane.id, modelIDs);
  const idle = lane.count === 0;
  const name = role?.name ?? lane.id;
  const shareText = `${Math.round(lane.share * 100)}`;
  return <button type="button" className={`lane${isLatest ? " latest" : ""}${selected ? " selected" : ""}${dimmed ? " dimmed" : ""}${idle ? " idle" : ""}`} style={{ ["--tint" as string]: color }}
    onClick={onToggle} title={selected ? "Show every model" : `Show only ${lane.id} in latency`} aria-pressed={selected}
    aria-label={`${name}, ${lane.id}, ${shareText}% of traffic, ${lane.count} turns`}>
    <span className="lane-label" style={{ width: LABEL }}>
      <span className="lane-share"><strong>{shareText}<small>%</small></strong><small>{lane.count === 1 ? "1 turn" : `${group(lane.count)} turns`}</small></span>
      <span className="lane-text"><span className="lane-name"><b>{name}</b>
        {isLatest && <em className="lane-badge">{isLive ? "live" : "latest"}</em>}
        {lane.delegatedCount > 0 && <em className="lane-sub" title={`${lane.delegatedCount} delegated subagent requests`}>{lane.delegatedCount === lane.count ? "sub" : `${lane.delegatedCount} sub`}</em>}</span>
        <code>{role ? <>{lane.id}{role.effort && <span> · {role.effort}</span>}</> : `${rate(lane.requestsPerSecond)} req/s`}</code></span>
    </span>
    <span className="tick-track">
      <i className="tick-baseline" />
      {ticks.map((tick, index) => {
        const newest = isLatest && index === ticks.length - 1;
        return <i key={index} className="tick" style={{ left: `calc(6px + ${tick.position} * (100% - 15px))`, height: newest ? 26 : 6 + 22 * tick.weight, opacity: newest ? 1 : 0.72 }} />;
      })}
      {isLatest && ticks.length > 0 && <i className={`tick-ring${pulses ? " pulse" : ""}`} style={{ left: `calc(6px + ${ticks[ticks.length - 1].position} * (100% - 15px) + 1.5px)` }} />}
    </span>
    {context !== undefined && <ContextMeter usage={context} idle={idle} />}
  </button>;
}

function ContextMeter({ usage, idle }: { usage: ContextUsage | null; idle: boolean }) {
  const fraction = usage?.fraction ?? null;
  const alarm = fraction == null ? "var(--tint)" : fraction >= 0.95 ? "var(--crit)" : fraction >= 0.8 ? "var(--warn)" : "var(--tint)";
  return <span className="context-meter" style={{ width: CONTEXT }} title={fraction == null ? "No context reading for this model in the session yet." : "Input tokens of the session's latest turn on this model, against its context window."}>
    <span className="context-row"><small>{idle ? "last context" : "context"}</small><b style={{ color: fraction != null && fraction >= 0.8 && !idle ? alarm : undefined }}>{fraction == null ? "—" : `${Math.round(fraction * 100)}%`}</b></span>
    <span className="context-bar"><i style={{ width: `${Math.min(Math.max(fraction ?? 0, 0), 1) * 100}%`, background: idle ? "rgba(109,125,118,.5)" : alarm }} /></span>
    <code>{usage?.inputTokens != null ? compact(usage.inputTokens) : "—"} / {usage?.contextWindow ? compact(usage.contextWindow) : "—"}</code>
  </span>;
}

function SessionPicker({ sessions, session, active, onSelect }: { sessions: Session[]; session: Session | null; active: Set<string>; onSelect: (id: string) => void }) {
  if (!sessions.length || !session) return <span className="session-waiting" title="The first Codex conversation routed through this run is picked here."><i aria-hidden="true" />Waiting for a session</span>;
  const live = sessions.filter((item) => active.has(item.id)).length;
  return <label className="session-picker" title={`Show only the turns one client conversation routed.${live ? ` ${live} active in the last 15 minutes, marked with a green dot.` : ""}`}>
    {active.has(session.id) ? <i className="session-live" aria-hidden="true" /> : <span aria-hidden="true" className="session-icon">◌</span>}
    <span>{session.shortTitle}</span><span aria-hidden="true" className="session-chevron">⌃⌄</span>
    <select aria-label="Session" value={session.id} onChange={(event) => onSelect(event.target.value)}>
      {sessions.map((item) => <option key={item.id} value={item.id}>{active.has(item.id) ? "● " : ""}{item.title}  —  {active.has(item.id) ? "active · " : ""}{item.detail}</option>)}
    </select>
  </label>;
}

// ---------- latency & latest turns ----------

function Card({ title, hint, accessory, children, className = "" }: { title: string; hint: string; accessory?: ReactNode; children: ReactNode; className?: string }) {
  return <section className={`act-card ${className}`} aria-label={title}><header><h3>{title}</h3><span>{hint}</span><span className="spacer" />{accessory}</header>{children}</section>;
}

function LatencyCard({ stats, modelIDs, selectedModelID, onShowAll }: { stats: ServerStats | null; modelIDs: string[]; selectedModelID: string | null; onShowAll: () => void }) {
  const models = (stats?.models ?? []).filter((model) => model.latency && (!selectedModelID || model.id === selectedModelID));
  const ceiling = Math.max(...models.map((model) => model.latency!.p99), 1);
  return <Card title="Latency" hint={selectedModelID ? `${selectedModelID} · p50 / p99, s` : "p50 / p99, seconds"} accessory={selectedModelID && <button className="card-link" onClick={onShowAll}>Show all</button>}>
    {models.length === 0 ? <p className="card-empty">No latency measurements yet. The proxy reports them once a model has answered.</p> :
      <div className="latency-rows" title="Switchyard measures latency per model since the proxy started; the routing log records token usage only.">{models.slice(0, 4).map((model) => {
        const color = tint(model.id, modelIDs);
        return <div className="latency-row" key={model.id}><span className="latency-id"><i style={{ background: color }} /><code>{model.id}</code></span>
          <span className="latency-track"><i className="track-line" /><i className="track-p99" style={{ width: `${(model.latency!.p99 / ceiling) * 100}%`, background: color }} />
            <i className="track-p50" style={{ left: `max(calc(${(model.latency!.p50 / ceiling) * 100}% - 1.5px), 0px)`, background: color }} /></span>
          <span className="latency-value">{seconds(model.latency!.p50)}<small> / {seconds(model.latency!.p99)}</small></span></div>;
      })}</div>}
  </Card>;
}

function LatestTurns({ records, session, modelIDs, roleOf, emptyReason, onOpenRequests }: {
  records: LogRecord[]; session: Session | null; modelIDs: string[]; roleOf: (record: LogRecord) => string | null; emptyReason: string | null; onOpenRequests: () => void;
}) {
  const turns: LogRecord[] = [];
  for (const record of records) {
    if (record.isClassifier || (session && record.sessionID !== session.id)) continue;
    turns.push(record);
    if (turns.length === 3) break;
  }
  return <Card title="Latest turns" hint="routing log" accessory={<button className="card-link" onClick={onOpenRequests}>All requests <span aria-hidden="true">→</span></button>}>
    {turns.length === 0 ? <p className="card-empty">{emptyReason ?? "No routed turns in this scope yet."}</p> :
      <table className="turns-table"><thead><tr><th>Time</th><th>Route</th><th>Model</th><th>Tokens</th><th>Cached</th></tr></thead><tbody>
        {turns.map((record) => <tr key={record.id} onClick={onOpenRequests} title="Open in requests">
          <td><code>{record.ts == null ? "—" : standardTime(record.ts)}</code></td>
          <td><i style={{ background: tint(record.modelIdentity, modelIDs) }} />{roleOf(record) ?? "—"}</td>
          <td><code>{record.modelIdentity}</code></td><td>{group(record.tokens.total)}</td>
          <td>{record.tokens.prompt > 0 ? `${percent(record.tokens.cached / record.tokens.prompt)}%` : "—"}</td></tr>)}
      </tbody></table>}
  </Card>;
}

// ---------- models & proxy, subagents ----------

function Panel({ title, note, accessory, children }: { title: string; note?: string; accessory?: ReactNode; children: ReactNode }) {
  return <section className="stats-panel" aria-label={title}><header><h3>{title}</h3>{note && <code>{note}</code>}<span className="spacer" />{accessory}</header>{children}</section>;
}

function ModelsAndProxy({ metrics, stats, session, roleName }: { metrics: Metrics; stats: ServerStats | null; session: Session | null; roleName: (target: string | null) => string | null }) {
  const counters: [string, string, boolean?][] = stats ? [
    ["requests", String(stats.totalRequests)], ["errors", String(stats.totalErrors), stats.totalErrors > 0],
    ["prompt tokens", group(stats.tokens.prompt)], ["completion tokens", group(stats.tokens.completion)],
    ...(stats.tokens.cached > 0 ? [["cached tokens", group(stats.tokens.cached)] as [string, string]] : []),
    ["overhead p50", `${milliseconds(stats.overhead.p50)} ms`], ["overhead p99", `${milliseconds(stats.overhead.p99)} ms`],
    ...(stats.classifierRequests > 0 ? [["classifier", String(stats.classifierRequests)] as [string, string]] : []),
    ...(stats.classifierErrors > 0 ? [["classifier errors", String(stats.classifierErrors), true] as [string, string, boolean]] : []),
    ...stats.fallbacks.map(([name, count]) => [`fallback · ${name}`, String(count)] as [string, string]),
  ] : [];
  return <Panel title="Models & Proxy" note={`${session?.shortTitle ?? "15m"} traffic · proxy lifetime stats`}
    accessory={stats && <code className={stats.totalErrors > 0 ? "crit-text" : ""}>{stats.totalRequests} total reqs · {stats.totalErrors} err</code>}>
    <table className="proxy-table"><thead><tr><th>Model</th><th>Target</th><th>Requests</th><th>Share</th><th>req/s</th><th>Errors</th></tr></thead><tbody>
      {metrics.shares.map((share) => {
        const errors = stats?.models.find((model) => model.id === share.id)?.errors;
        return <tr key={share.id} className={share.count === 0 ? "idle" : ""}><td><code>{share.id}</code></td><td>{roleName(share.target) ?? "—"}</td>
          <td>{share.delegatedCount > 0 ? `${share.count} (${share.delegatedCount} sub)` : share.count}</td><td>{percent(share.share)}%</td><td>{rate(share.requestsPerSecond)}</td>
          <td className={(errors ?? 0) > 0 ? "crit-text" : ""}>{errors ?? "—"}</td></tr>;
      })}
    </tbody></table>
    {stats && <div className="proxy-counters"><div className="counters-head"><span>PROXY LIFETIME TOTALS</span><span>since switchyard-server started</span></div>
      <div className="counters-grid">{counters.map(([label, value, crit]) => <div key={label}><span>{label}</span><code className={crit ? "crit-text" : ""}>{value}</code></div>)}</div></div>}
  </Panel>;
}

function Subagents({ metrics, modelIDs }: { metrics: Metrics; modelIDs: string[] }) {
  const ratio = metrics.count ? Math.round((metrics.delegatedTokens / Math.max(metrics.tokens, 1)) * 100) : 0;
  return <Panel title="Subagents" note={`${metrics.delegatedCount} calls · ${metrics.uniqueSubagentsCount} subagents · ${group(metrics.delegatedTokens)} tokens (${ratio}% of volume)`}>
    {metrics.subagentIdentityUnsupported && <p className="identity-warning inline"><span aria-hidden="true">▲</span>Harness does not send subagent identity (e.g. Claude Code &lt; 2.1.139). Delegated requests route via parent route.</p>}
    {metrics.subagentRoles.size > 0 && <div className="sub-block"><span className="counters-label">ROLES BREAKDOWN</span><div className="sub-roles">
      {[...metrics.subagentRoles].sort((a, b) => b[1] - a[1]).map(([role, count]) => <span key={role}><code>{role}</code><small>{count}</small></span>)}</div></div>}
    {metrics.delegatedShares.length > 0 && <div className="sub-block"><span className="counters-label">DELEGATED TRAFFIC BY MODEL</span>
      {metrics.delegatedShares.map((share) => <div className="sub-row" key={share.id}><i style={{ background: tint(share.id, modelIDs) }} /><code>{share.id}</code><span className="spacer" />
        <span>{share.count} calls</span><small>({Math.round(share.share * 100)}%)</small><span>{group(share.tokens)} tok</span></div>)}</div>}
  </Panel>;
}
