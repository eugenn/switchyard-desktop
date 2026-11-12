import { useCallback, useContext, useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { flushSync } from "react-dom";
import { algorithms, builtInRoles, connectionInfo, connectionOf, servingTargets, type Algorithm, type ConnectionId, type DecisionEngine, type ModelTarget, type RouteSettings, type RoutingRole } from "./api";
import { families, guides, variableJob } from "./routingGuide";
import { ConnectionPicker, ConnectionsContext } from "./ConnectionPicker";
import { routeStory, storyEvents, type StoryBeat } from "./routeStory";
import "./routeCanvas.css";

type Change = (next: Partial<RouteSettings>) => void;
const classifierId = builtInRoles.find((role) => role.kind === "classifier")!.id;
const decisionAlgorithms: Algorithm[] = ["capability", "llm_classifier", "composite"];
const optionalJudgeAlgorithms: Algorithm[] = ["stage_router", "plan_execute", "vgr"];
const modelPattern = /^[a-zA-Z0-9._:/-]{1,200}$/;
const pretty = (key: string) => key === "efficient" ? "Efficient" : key === "capable" ? "Capable" : key;
const reducedMotion = () => typeof window !== "undefined" && !!window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;

type Highlight = ConnectionId | "typesafe" | null;
export const engineInfo: Record<"llm" | DecisionEngine, { name: string; line: string; model: string; via: string }> = {
  llm: { name: "LLM judge", line: "Any connected chat model reads the task and answers in JSON. Flexible, costs a model call.", model: "", via: "" },
  jev: { name: "Jev", line: "A decision model that returns the probability of each choice. Fast and calibrated by a cutoff.", model: "jev-latest", via: "TypeSafe" },
  mercury: { name: "Mercury Decide", line: "Inception's decision model, served through OpenRouter's decisions API.", model: "inception/mercury-decide", via: "OpenRouter" },
};

/** Which connections a setup relies on, keyed by the slot names that use them. */
export function connectionUsage(settings: RouteSettings): Record<ConnectionId | "typesafe", string[]> {
  const usage: Record<ConnectionId | "typesafe", string[]> = { chatgpt: [], openai: [], anthropic: [], openrouter: [], typesafe: [] };
  const algorithm = algorithms.find((item) => item.value === settings.algorithm)!;
  if (algorithm.shape === "none") return usage;
  servingTargets(settings).forEach((target, index) => usage[connectionOf(settings, target)].push(algorithm.shape === "variable" ? `Target ${index + 1}` : guides[settings.algorithm].slots[index]?.title ?? pretty(target.key)));
  const judge = guides[settings.algorithm].judge?.title ?? "Judge";
  const jev = settings.jevClassifier;
  if (jev) usage[jev.engine === "mercury" ? "openrouter" : "typesafe"].push(judge);
  else if (!settings.judgeTarget && (settings.judgeModel || algorithm.judge)) usage[connectionOf(settings, { connection: settings.judgeConnection })].push(judge);
  return usage;
}

/** Changing strategy resets strategy-specific inputs; pair models, their providers and the role library stay. */
export function strategyReset(value: Algorithm, previous?: RouteSettings): Partial<RouteSettings> {
  const shape = algorithms.find((item) => item.value === value)!.shape;
  const pairTargets = previous?.targets?.length === 2 && previous.targets[0].key === "efficient" && previous.targets[1].key === "capable";
  return { algorithm: value, classifyTrigger: value === "composite" ? "user_turn" : "every_request", targets: shape === "pair" && pairTargets ? previous!.targets : [], additionalTargets: [], nativeRouteOptions: "", judgeModel: "", judgeTarget: null, judgeOptions: "", jevClassifier: null, defaultTarget: "", reviewerSystemPrompt: "" };
}

/** Runs a state change as a view transition, so shared nodes morph between strategies. */
export function morph(update: () => void) {
  const doc = document as Document & { startViewTransition?: (callback: () => void) => unknown };
  if (!doc.startViewTransition || reducedMotion()) { update(); return; }
  doc.startViewTransition(() => flushSync(update));
}

/* ---------------------------------------------------------------- strategy deck */

function Glyph({ value }: { value: Algorithm }) {
  const { shape, judge } = algorithms.find((item) => item.value === value)!;
  const fan = shape === "variable" ? [4, 10, 16] : shape === "pair" ? [6, 14] : shape === "single" ? [10] : [];
  return <svg className="glyph" viewBox="0 0 28 20" aria-hidden="true">
    <circle cx="3" cy="10" r="2" className="g-src" />
    {judge && <rect x="10" y="7" width="6" height="6" rx="1.2" transform="rotate(45 13 10)" className="g-judge" />}
    {fan.map((y, index) => <path key={y} d={`M5 10 C ${judge ? 17 : 13} 10, 17 ${y}, 24 ${y}`} className={index === fan.length - 1 && fan.length > 1 ? "g-cap" : "g-eff"} />)}
    {fan.map((y, index) => <circle key={`d${y}`} cx="25" cy={y} r="1.8" className={index === fan.length - 1 && fan.length > 1 ? "g-cap-dot" : "g-eff-dot"} />)}
    {!fan.length && <path d="M5 10 H22" className="g-none" />}
  </svg>;
}

export function StrategyDeck({ settings, disabled, onPick, hover, setHover }: { settings: RouteSettings; disabled: boolean; onPick: (value: Algorithm) => void; hover: Algorithm | null; setHover: (value: Algorithm | null) => void }) {
  return <section className="deck" aria-label="Strategy">
    <fieldset disabled={disabled} className="deck-families" onMouseLeave={() => setHover(null)}>
      <legend className="sr-only">Routing strategy</legend>
      {families.map((family) => <div key={family.id} className={`deck-family ${family.id}`}>
        <span className="deck-family-title">{family.title}</span>
        <div className="deck-chips">
          {algorithms.filter((item) => guides[item.value].family === family.id).map((item) => {
            const active = item.value === settings.algorithm;
            return <label key={item.value} className={`deck-chip${active ? " active" : ""}`} onMouseEnter={() => setHover(item.value)}
              title={guides[item.value].tagline}>
              <input type="radio" name="algorithm" value={item.value} checked={active} onChange={() => onPick(item.value)}
                onFocus={() => setHover(item.value)} onBlur={() => setHover(null)} />
              <Glyph value={item.value} />
              <span className="deck-chip-name">{item.label}{item.value === "auto" && <em className="badge">Recommended</em>}{item.value === "prefill_router" && <em className="badge muted">Not bundled</em>}</span>
            </label>;
          })}
        </div>
      </div>)}
    </fieldset>
  </section>;
}

/** The selected strategy, or the hovered one as a preview, in one line above the canvas. */
export function StrategyBrief({ settings, hover }: { settings: RouteSettings; hover: Algorithm | null }) {
  const shown = hover ?? settings.algorithm;
  const guide = guides[shown];
  const current = algorithms.find((item) => item.value === shown)!;
  return <div className={`deck-brief canvas-brief${hover && hover !== settings.algorithm ? " previewing" : ""}`} aria-live="polite">
      <span className="deck-brief-name">{hover && hover !== settings.algorithm ? <><small>Preview</small>{current.label}</> : <><small>Selected</small>{current.label}</>}</span>
      <p>{guide.tagline}</p>
      <dl>
        <div><dt>Decides by</dt><dd title={guide.decides}>{guide.decides}</dd></div>
        <div><dt>Needs</dt><dd>{guide.needs}</dd></div>
        <div><dt>Extra cost</dt><dd title={guide.cost}>{guide.cost}</dd></div>
      </dl>
    </div>;
}

/* ---------------------------------------------------------------- canvas */

type Selection = { kind: "slot"; index: number } | { kind: "judge" };
type Rule = { id: string; title: string; note: string };

const rules: Partial<Record<Algorithm, Rule>> = {
  auto: { id: "rule", title: "Tool-result signals", note: "Reads tool results in each request" },
  stage_router: { id: "rule", title: "Tool-result signals", note: "Reads tool results from recent turns" },
  plan_execute: { id: "rule", title: "Plan, then execute", note: "Capable plans, Efficient carries out" },
  random: { id: "rule", title: "Random split", note: "Equal share, request text not read" },
  passthrough: { id: "rule", title: "Direct", note: "Every request, one model" },
  vgr: { id: "rule", title: "Shadow verifier", note: "Efficient drafts are checked, not served" },
  prefill_router: { id: "rule", title: "Checkpoint", note: "Your trained classifier picks" },
  noop: { id: "rule", title: "No model", note: "Answers OK for smoke tests" },
};

export function RouteCanvas({ settings, change, disabled, highlight, hover }: { settings: RouteSettings; change: Change; disabled: boolean; highlight: Highlight; hover: Algorithm | null }) {
  const algorithm = algorithms.find((item) => item.value === settings.algorithm)!;
  const guide = guides[settings.algorithm];
  const roles = settings.roles ?? builtInRoles;
  const targets = servingTargets(settings);
  const allTargets = [...targets, ...(settings.additionalTargets ?? [])];
  const variable = algorithm.shape === "variable";
  const optionalJudge = !algorithm.judge && optionalJudgeAlgorithms.includes(settings.algorithm);
  const [judgeAdded, setJudgeAdded] = useState(false);
  const judgeInUse = !!settings.judgeModel || !!settings.judgeTarget || judgeAdded;
  const showJudge = algorithm.judge || (optionalJudge && judgeInUse);
  const [selected, setSelected] = useState<Selection | null>(targets.length ? { kind: "slot", index: 0 } : null);
  const [beat, setBeat] = useState<number | null>(null);
  const [playing, setPlaying] = useState(false);
  const rule = rules[settings.algorithm];
  const classifier = settings.algorithm === "llm_classifier" && !settings.nativeRouteOptions?.trim();

  useEffect(() => { if (selected?.kind === "slot" && selected.index >= targets.length) setSelected(targets.length ? { kind: "slot", index: targets.length - 1 } : null); }, [selected, targets.length]);
  useEffect(() => { if (selected?.kind === "judge" && !showJudge) setSelected(targets.length ? { kind: "slot", index: 0 } : null); }, [selected, showJudge, targets.length]);
  useEffect(() => {
    if (!playing) return;
    const timer = setTimeout(() => { if (beat === null || beat < storyEvents.length - 1) setBeat((beat ?? -1) + 1); else setPlaying(false); }, beat === null ? 80 : 2600);
    return () => clearTimeout(timer);
  }, [playing, beat, storyEvents.length]);

  const updateTarget = (index: number, patch: Partial<ModelTarget>) => {
    if (variable || settings.targets?.length || patch.connection) {
      change({ targets: targets.map((target, position) => position === index ? { ...target, ...patch } : target) });
    } else if (index === 0) {
      change({ efficientModel: patch.model ?? settings.efficientModel, efficientRoleId: patch.roleId === undefined ? settings.efficientRoleId : patch.roleId, efficientOptions: patch.nativeOptions ?? settings.efficientOptions });
    } else {
      change({ capableModel: patch.model ?? settings.capableModel, capableRoleId: patch.roleId === undefined ? settings.capableRoleId : patch.roleId, capableOptions: patch.nativeOptions ?? settings.capableOptions });
    }
  };
  const addTarget = () => {
    let suffix = 1;
    while (allTargets.some((target) => target.key === `target_${suffix}`)) suffix++;
    const last = targets[targets.length - 1];
    change({ targets: [...targets, { key: `target_${suffix}`, model: "", roleId: null, nativeOptions: "", ...(last ? { connection: connectionOf(settings, last) } : {}) }] });
    setSelected({ kind: "slot", index: targets.length });
  };
  const slotTitle = (index: number) => variable ? `Target ${index + 1}` : guide.slots[index]?.title ?? `Target ${index + 1}`;
  const slotJob = (index: number) => variable ? variableJob(settings.algorithm) : guide.slots[index]?.job ?? "";
  const tone = (index: number) => variable ? "neutral" : algorithm.shape === "single" ? "efficient" : index === 0 ? "efficient" : "capable";
  const removeJudge = () => { setJudgeAdded(false); change({ judgeModel: "", judgeTarget: null, judgeOptions: "" }); setSelected(targets.length ? { kind: "slot", index: 0 } : null); };
  const judgeTitle = guide.judge?.title ?? "Judge";
  const nameOf = (key: string) => { const index = targets.findIndex((target) => target.key === key); return index < 0 ? pretty(key) : slotTitle(index); };
  const story = useMemo(() => routeStory(settings, nameOf), [settings]); // eslint-disable-line react-hooks/exhaustive-deps
  const active: StoryBeat | null = beat === null ? null : story[beat];

  const lit = (key: string) => active ? active.serves.includes(key) : false;
  const shadowLit = (key: string) => active?.shadow?.includes(key) ?? false;
  const providerLit = (provider: ConnectionId | "typesafe") => highlight === provider;
  const judgeProvider: ConnectionId | "typesafe" = settings.jevClassifier ? (settings.jevClassifier.engine === "mercury" ? "openrouter" : "typesafe") : connectionOf(settings, { connection: settings.judgeConnection });
  const { connected } = useContext(ConnectionsContext);
  const chatConnected = (["chatgpt", "openai", "anthropic", "openrouter"] as const).some((id) => connected.has(id));

  const graph = useRef<HTMLDivElement>(null);
  const edges = useMemo(() => {
    const list: { from: string; to: string; tone: string }[] = [];
    const deciders = [...(rule ? ["rule"] : []), ...(showJudge ? ["judge"] : [])];
    const slotIds = targets.map((target, index) => ({ id: `slot-${index}`, key: target.key, tone: tone(index) }));
    // The advisor reviews the executor's work instead of choosing a model, so requests go straight to the executor.
    const advisor = settings.algorithm === "advisor";
    const sinks = deciders.length && !advisor ? deciders : slotIds.map((slot) => slot.id);
    for (const sink of sinks) list.push({ from: "source", to: sink, tone: "source" });
    for (const decider of deciders) for (const slot of slotIds) list.push({ from: decider, to: slot.id, tone: advisor ? "judge" : slot.tone });
    return list;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rule, showJudge, targets.length, settings.algorithm, algorithm.shape]);
  const edgeLit = (edge: { from: string; to: string }) => {
    if (!active) return false;
    const slotLit = (id: string) => id.startsWith("slot-") && (lit(targets[Number(id.slice(5))]?.key) || shadowLit(targets[Number(id.slice(5))]?.key));
    if (edge.from === "source") return edge.to === "judge" ? active.judge : edge.to === "rule" ? active.serves.length > 0 && !(showJudge && active.judge && !rule) : slotLit(edge.to);
    if (edge.to === "judge") return active.judge;
    if (edge.from === "judge") return active.judge && slotLit(edge.to);
    return slotLit(edge.to);
  };
  const paths = useConnectors(graph, edges, [settings, selected, showJudge]);

  const { onConnect } = useContext(ConnectionsContext);
  return <section className={`canvas-panel${active ? " storytelling" : ""}${chatConnected ? "" : " ghost"}`} aria-label="Route">
    <StrategyBrief settings={settings} hover={hover} />
    {!chatConnected && settings.algorithm !== "noop" && <div className="ghost-cta" role="note"><strong>Connect a provider to assign models</strong><span>You can still browse strategies and play the session walkthrough.</span>{onConnect && <button type="button" className="button primary small" onClick={onConnect}>Connect providers</button>}</div>}
    <div className="canvas-body">
      <div className="graph" ref={graph}>
        <svg className="wires" aria-hidden="true">
          <defs>
            <linearGradient id="wire-fade" x1="0" x2="1"><stop offset="0" stopColor="currentColor" stopOpacity=".15" /><stop offset="1" stopColor="currentColor" stopOpacity=".55" /></linearGradient>
          </defs>
          {paths.map(({ edge, d }, index) => {
            const on = edgeLit(edge);
            return <g key={`${edge.from}-${edge.to}`} className={`wire ${edge.tone}${on ? " lit" : ""}${active && !on ? " dim" : ""}`}>
              <path d={d} className="wire-base" />
              <path d={d} className="wire-flow" style={{ animationDelay: `${index * -0.37}s` }} />
              {on && !reducedMotion() && <circle r="3.2" className="wire-spark"><animateMotion dur="1.1s" repeatCount="indefinite" path={d} /></circle>}
            </g>;
          })}
        </svg>
        <div className="graph-col request-col">
          <div className="node request-node" data-port="source">
            <span className="node-kicker">Request</span>
            <strong>Codex</strong>
            <small>via :4100</small>
          </div>
        </div>
        <div className="graph-col decider-col">
          {rule && <div className={`node rule-node${active && active.serves.length && !active.judge ? " lit" : ""}`} data-port="rule" style={{ viewTransitionName: "rule-node" }}>
            <span className="node-kicker">Rule</span><strong>{rule.title}</strong><small>{rule.note}</small>
          </div>}
          {showJudge && <JudgeNode settings={settings} change={change} title={judgeTitle} job={(guide.judge?.job ?? "").replace(/^Optional\. /, "")} optional={optionalJudge}
            selected={selected?.kind === "judge"} onSelect={() => setSelected({ kind: "judge" })} lit={!!active?.judge} dim={!!active && !active.judge}
            glow={providerLit(judgeProvider)} />}
          {optionalJudge && !showJudge && <button type="button" className="node ghost-node" onClick={() => { setJudgeAdded(true); setSelected({ kind: "judge" }); }}>
            <span aria-hidden="true" className="ghost-plus">+</span><span><strong>Add optional judge</strong><small>{guide.judge?.job.replace(/^Optional\. /, "")}</small></span>
          </button>}
        </div>
        <div className={`graph-col slot-col${targets.length > 2 ? " many" : ""}`}>
          {targets.length === 0 && <p className="slots-empty">No-op answers OK without calling a model, so there is nothing to assign.</p>}
          {targets.map((target, index) => {
            const described = roles.some((role) => role.id === target.roleId && role.kind === "target" && role.text.trim());
            return <SlotNode key={index} index={index} target={target} roles={roles} title={slotTitle(index)} job={slotJob(index)} tone={tone(index)} variable={variable}
              roleNeed={classifier ? "required" : algorithm.judge ? "read by judge" : "optional"} roleMissing={classifier && !described}
              selected={selected?.kind === "slot" && selected.index === index} onSelect={() => setSelected({ kind: "slot", index })}
              lit={lit(target.key)} shadow={shadowLit(target.key)} dim={!!active && !lit(target.key) && !shadowLit(target.key)} glow={providerLit(connectionOf(settings, target))} connection={connectionOf(settings, target)}
              onChange={(patch) => updateTarget(index, patch)} />;
          })}
          {variable && targets.length < 6 && <button type="button" className="add-slot" aria-label="Add routing target" onClick={addTarget}><span aria-hidden="true">+</span>Add routing target<small>{targets.length} of 6</small></button>}
        </div>
      </div>
      <Inspector settings={settings} change={change} disabled={disabled} selection={selected} targets={targets} allTargets={allTargets} roles={roles}
        title={selected?.kind === "slot" ? slotTitle(selected.index) : judgeTitle} variable={variable}
        updateTarget={updateTarget} onRemoveTarget={variable && targets.length > 2 && selected?.kind === "slot" ? () => { const index = selected.index; change({ targets: targets.filter((_, position) => position !== index) }); setSelected({ kind: "slot", index: Math.max(0, index - 1) }); } : undefined}
        onRemoveJudge={optionalJudge ? removeJudge : undefined} />
    </div>
    {settings.algorithm === "prefill_router" && <div className="canvas-note"><p className="editor-warning">Optional server feature. The bundled server does not include prefill inference, and there is no silent fallback.</p>
      <label>Checkpoint path<input value={settings.checkpoint ?? ""} onChange={(event) => change({ checkpoint: event.target.value })} disabled={disabled} /></label></div>}
    <Story nameOf={nameOf} story={story} beat={beat} playing={playing} onBeat={(index) => { setPlaying(false); setBeat(index === beat ? null : index); }}
      onPlay={() => { if (playing) { setPlaying(false); return; } setBeat(null); setPlaying(true); }} label={algorithm.label} />
  </section>;
}

/** Measures node ports inside the graph and returns a curved wire for each edge. */
function useConnectors(container: React.RefObject<HTMLDivElement | null>, edges: { from: string; to: string; tone: string }[], deps: unknown[]) {
  const [paths, setPaths] = useState<{ edge: { from: string; to: string; tone: string }; d: string }[]>([]);
  const measure = useCallback(() => {
    const root = container.current;
    if (!root) return;
    const box = root.getBoundingClientRect();
    const port = (id: string) => root.querySelector<HTMLElement>(`[data-port="${id}"]`)?.getBoundingClientRect();
    const next = edges.flatMap((edge) => {
      const a = port(edge.from), b = port(edge.to);
      if (!a || !b || !a.width || !b.width) return [];
      const backwards = b.left < a.right;
      const x1 = backwards ? a.left + a.width / 2 - box.left : a.right - box.left, y1 = backwards ? a.top - box.top : a.top + a.height / 2 - box.top;
      const x2 = backwards ? b.left + b.width / 2 - box.left : b.left - box.left, y2 = backwards ? b.bottom - box.top : b.top + b.height / 2 - box.top;
      const bend = Math.max(28, Math.abs(x2 - x1) * 0.5);
      const d = backwards ? `M ${x1} ${y1} C ${x1} ${y1 - 30}, ${x2} ${y2 + 30}, ${x2} ${y2}` : `M ${x1} ${y1} C ${x1 + bend} ${y1}, ${x2 - bend} ${y2}, ${x2} ${y2}`;
      return [{ edge, d }];
    });
    setPaths((previous) => JSON.stringify(previous) === JSON.stringify(next) ? previous : next);
  }, [container, edges]);
  useLayoutEffect(() => { measure(); }, [measure, ...deps]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    const root = container.current;
    if (!root || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(() => measure());
    observer.observe(root);
    root.querySelectorAll("[data-port]").forEach((node) => observer.observe(node));
    return () => observer.disconnect();
  }, [container, measure, ...deps]); // eslint-disable-line react-hooks/exhaustive-deps
  return paths;
}

function ConnectionTag({ connection }: { connection: ConnectionId }) {
  const { connected } = useContext(ConnectionsContext);
  const off = !connected.has(connection);
  return <span className={`provider-tag ${connection}${off ? " off" : ""}`} title={off ? `${connectionInfo[connection].name} is not connected` : undefined}>
    <i aria-hidden="true" />{connectionInfo[connection].short}<em className={`billing ${off ? "off" : connectionInfo[connection].billing.toLowerCase()}`}>{off ? "not connected" : connectionInfo[connection].billing}</em></span>;
}

function SlotNode({ index, target, connection, roles, title, job, tone, variable, roleNeed, roleMissing, selected, onSelect, lit, shadow, dim, glow, onChange }: {
  connection: ConnectionId; index: number; target: ModelTarget; roles: RoutingRole[]; title: string; job: string; tone: string; variable: boolean; roleNeed: string; roleMissing: boolean;
  selected: boolean; onSelect: () => void; lit: boolean; shadow: boolean; dim: boolean; glow: boolean; onChange: (patch: Partial<ModelTarget>) => void;
}) {
  const empty = !target.model.trim();
  const invalid = !modelPattern.test(target.model);
  const role = roles.find((item) => item.id === target.roleId);
  const { connected, catalog, onConnect } = useContext(ConnectionsContext);
  const offline = !connected.has(connection);
  return <section className={`node slot-node ${tone}${offline ? " offline" : ""}${selected ? " selected" : ""}${lit ? " lit" : ""}${shadow ? " shadow" : ""}${dim ? " dim" : ""}${glow ? " glow" : ""}${(invalid && !empty) || roleMissing ? " invalid" : ""}`}
    aria-label={title} data-port={`slot-${index}`} style={{ viewTransitionName: `slot-${variable ? index : target.key}` }}
    onClick={onSelect} onFocusCapture={onSelect}>
    <header>
      <span className="slot-name">{title}</span>
      {variable && <code className="slot-key">{target.key}</code>}
      <ConnectionTag connection={connection} />
      {lit && <span className="serving-badge">serving</span>}{shadow && <span className="serving-badge shadow">shadow</span>}
    </header>
    {job && <p className="slot-job">{job}</p>}
    <div className="node-fields">
      <ConnectionPicker label={`${title} model`} connection={connection} model={target.model} connected={connected} catalog={catalog} invalid={invalid} placeholder="Model ID"
        onChange={(next) => onChange(next.connection === connection ? { model: next.model } : { model: next.model, connection: next.connection })} onConnectMore={onConnect} />
      <select aria-label={`${title} role`} aria-invalid={roleMissing} value={target.roleId ?? ""} onChange={(event) => onChange({ roleId: event.target.value || null })}>
        <option value="">{roleNeed === "required" ? "Choose a role" : "No role"}</option>
        {roles.filter((item) => item.kind === "target").map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}
      </select>
    </div>
    {invalid && !empty ? <small className="field-issue">Use the exact model ID: letters, digits and . _ : / - only.</small>
      : roleMissing ? <small className="field-issue">Pick a role with a description: the judge reads it to choose this target.</small>
      : role ? <small className="field-hint role-line"><b>{role.effort ?? "default"} effort</b> {role.text}</small>
      : offline ? <small className="field-issue">{connectionInfo[connection].name} is not connected. Connect it, or pick a model from another provider.</small>
      : empty ? <small className="field-hint">Pick a model from a connected provider, or type its ID.</small> : null}
  </section>;
}

function JudgeNode({ settings, change, title, job, optional, selected, onSelect, lit, dim, glow }: {
  settings: RouteSettings; change: Change; title: string; job: string; optional: boolean; selected: boolean; onSelect: () => void; lit: boolean; dim: boolean; glow: boolean;
}) {
  const jev = settings.jevClassifier;
  const engine = jev ? jev.engine ?? "jev" : "llm";
  const shared = !!settings.judgeTarget;
  const judgeMissing = !jev && !shared && !modelPattern.test(settings.judgeModel ?? "");
  const { connected, catalog, onConnect } = useContext(ConnectionsContext);
  const judgeConnection = connectionOf(settings, { connection: settings.judgeConnection });
  return <section className={`node judge-node${selected ? " selected" : ""}${lit ? " lit" : ""}${dim ? " dim" : ""}${glow ? " glow" : ""}${judgeMissing && settings.judgeModel ? " invalid" : ""}`}
    aria-label={title} data-port="judge" style={{ viewTransitionName: "judge-node" }} onClick={onSelect} onFocusCapture={onSelect}>
    <header>
      <span className="slot-name">{title}{optional && <small>optional</small>}</span>
      <span className={`engine-pill ${engine}`}>{engineInfo[engine].name}</span>
    </header>
    <p className="slot-job">{job}</p>
    <div className="node-fields single">
      {jev ? <input aria-label="Decision model" title={jev.modelID} spellCheck={false} value={jev.modelID} onChange={(event) => change({ jevClassifier: { ...jev, modelID: event.target.value } })} />
        : shared ? <p className="judge-shared">Same model as <b>{pretty(settings.judgeTarget!)}</b></p>
        : <ConnectionPicker label={`${title} model`} connection={judgeConnection} model={settings.judgeModel ?? ""} connected={connected} catalog={catalog} invalid={judgeMissing} placeholder="Judge model ID"
          onChange={(next) => change({ judgeModel: next.model, judgeConnection: next.connection })} onConnectMore={onConnect} />}
    </div>
    {jev && settings.algorithm !== "llm_classifier" && <CutoffMeter cutoff={jev.cutoff} compact />}
    {!jev && !shared && judgeMissing && !settings.judgeModel && <small className="field-hint">A fast model that reliably returns JSON works best.</small>}
    {!jev && !shared && judgeMissing && settings.judgeModel && <small className="field-issue">Use the exact model ID: letters, digits and . _ : / - only.</small>}
  </section>;
}

/** Probability bar: below the cutoff the request starts on Efficient, above it on Capable. */
function CutoffMeter({ cutoff, compact }: { cutoff: number; compact?: boolean }) {
  const percent = Math.min(100, Math.max(0, (Number.isFinite(cutoff) ? cutoff : 0) * 100));
  return <div className={`cutoff-meter${compact ? " compact" : ""}`} aria-hidden="true">
    <div className="cutoff-track"><span className="zone efficient" style={{ width: `${percent}%` }} /><span className="zone capable" style={{ width: `${100 - percent}%` }} /><i style={{ left: `${percent}%` }} /></div>
    {!compact && <div className="cutoff-legend"><span>Efficient</span><span>P(capable) &gt; {cutoff.toFixed(2)} → Capable</span></div>}
  </div>;
}

/* ---------------------------------------------------------------- inspector */

function Inspector({ settings, change, disabled, selection, targets, allTargets, roles, title, variable, updateTarget, onRemoveTarget, onRemoveJudge }: {
  settings: RouteSettings; change: Change; disabled: boolean; selection: Selection | null; targets: ModelTarget[]; allTargets: ModelTarget[]; roles: RoutingRole[]; title: string; variable: boolean;
  updateTarget: (index: number, patch: Partial<ModelTarget>) => void; onRemoveTarget?: () => void; onRemoveJudge?: () => void;
}) {
  if (!selection || (selection.kind === "slot" && !targets[selection.index])) return <aside className="inspector empty" aria-label="Inspector"><p>Select a node to see its settings.</p></aside>;
  return <aside className="inspector" aria-label={`${title} settings`} key={selection.kind === "slot" ? `slot-${selection.index}` : "judge"}>
    <fieldset disabled={disabled} aria-label={`${title} settings`}>
      <div className="inspector-title"><span>Inspector</span>{title}</div>
      {selection.kind === "slot" ? <SlotInspector connection={connectionOf(settings, targets[selection.index])} target={targets[selection.index]} title={title} roles={roles} variable={variable} onChange={(patch) => updateTarget(selection.index, patch)} onRemove={onRemoveTarget} />
        : <JudgeInspector settings={settings} change={change} targets={targets} allTargets={allTargets} roles={roles} title={title} onRemove={onRemoveJudge} />}
    </fieldset>
  </aside>;
}

function Segmented<T extends string>({ label, value, options, onChange }: { label: string; value: T; options: { value: T; label: ReactNode; name?: string; disabled?: boolean; hint?: string }[]; onChange: (value: T) => void }) {
  return <div className="segmented" role="radiogroup" aria-label={label}>
    {options.map((option) => <label key={option.value} className={`${option.value === value ? "on" : ""}${option.disabled ? " off" : ""}`} title={option.hint}>
      <input type="radio" name={label} aria-label={option.name} value={option.value} checked={option.value === value} disabled={option.disabled} onChange={() => onChange(option.value)} />
      <span>{option.label}</span>
    </label>)}
  </div>;
}

function SlotInspector({ connection, target, title, roles, variable, onChange, onRemove }: { connection: ConnectionId; target: ModelTarget; title: string; roles: RoutingRole[]; variable: boolean; onChange: (patch: Partial<ModelTarget>) => void; onRemove?: () => void }) {
  const role = roles.find((item) => item.id === target.roleId);
  const { connected, onConnect } = useContext(ConnectionsContext);
  return <>
    <div className="inspector-block">
      <span className="field-label">Served by</span>
      <p className="served-by"><span className={`connection-dot ${connection}`} aria-hidden="true" /><b>{connectionInfo[connection].name}</b>
        <em className={`billing ${connectionInfo[connection].billing.toLowerCase()}`}>{connectionInfo[connection].billing}</em></p>
      <p className="inspector-hint">{connection === "chatgpt" ? "Billed to your ChatGPT plan. Pick a model from another connection in the model field to switch." : "Billed per token to this provider's API key. Pick a model from another connection in the model field to switch."}</p>
      {!connected.has(connection) && <p className="inspector-warn" role="note"><b>Not connected.</b> Start needs this connection. {onConnect && <button type="button" className="text-button" onClick={onConnect}>Connect {connectionInfo[connection].short}</button>}</p>}
      {connection !== "chatgpt" && connection !== "openai" && <p className="inspector-hint">{connectionInfo[connection].name} does not report reasoning effort or image support, so they are unknown for this model. A role's effort is sent as is.</p>}
    </div>
    <div className="inspector-block">
      <span className="field-label">Role</span>
      {role ? <p className="role-preview"><b>{role.name}</b><span>{role.effort ?? "default"} effort</span>{role.text || "No routing description."}</p> : <p className="inspector-hint">No role. A role sets effort and a prompt, and describes the target to a judge. Edit roles on the Roles page.</p>}
    </div>
    <details className="inspector-more" open={!!target.nativeOptions.trim() || undefined}>
      <summary>{target.nativeOptions.trim() ? "Custom options set" : "More options"}</summary>
      {variable && <label className="slot-field"><span className="field-label">Target key</span><input aria-label="Target key" value={target.key} onChange={(event) => onChange({ key: event.target.value })} /></label>}
      <label className="slot-field"><span className="field-label">Native target options (TOML)</span><textarea aria-label={`${title} native options (TOML)`} value={target.nativeOptions} onChange={(event) => onChange({ nativeOptions: event.target.value })} placeholder={'reasoning_effort = "high"'} /></label>
      <small className="field-hint">Overrides the role. Cannot change id or llm_client.</small>
    </details>
    {onRemove && <button type="button" className="text-button danger" onClick={onRemove}>Remove {title.toLowerCase()}</button>}
  </>;
}

function JudgeInspector({ settings, change, targets, allTargets, roles, title, onRemove }: { settings: RouteSettings; change: Change; targets: ModelTarget[]; allTargets: ModelTarget[]; roles: RoutingRole[]; title: string; onRemove?: () => void }) {
  const { connected, onConnect } = useContext(ConnectionsContext);
  const algorithm = settings.algorithm;
  const jev = settings.jevClassifier;
  const engine = jev ? jev.engine ?? "jev" : "llm";
  const decides = decisionAlgorithms.includes(algorithm);
  const shared = !!settings.judgeTarget;
  const setEngine = (value: "llm" | DecisionEngine) => {
    if (value === "llm") { change({ jevClassifier: null }); return; }
    const keep = !!jev && (jev.engine ?? "jev") === value;
    const cutoff = keep ? jev!.cutoff : value === "mercury" && algorithm === "composite" ? 0.92 : 0.6;
    change({ jevClassifier: { modelID: keep ? jev!.modelID : engineInfo[value].model, cutoff, instructions: jev?.instructions ?? "", ...(value === "mercury" ? { engine: value } : {}) }, judgeModel: "", judgeTarget: null, judgeOptions: "", nativeRouteOptions: "" });
  };
  return <>
    <div className="inspector-block">
      <span className="field-label">Decides with</span>
      <Segmented label={`${title} engine`} value={engine} onChange={setEngine}
        options={(["llm", "jev", "mercury"] as const).map((value) => ({ value, label: value === "mercury" ? "Mercury" : value === "llm" ? "LLM" : "Jev", name: engineInfo[value].name, disabled: value !== "llm" && !decides, hint: value !== "llm" && !decides ? "Decision models work with Capability, Composite and Custom classifier." : undefined }))} />
      {engine !== "llm" && !connected.has(engine === "jev" ? "typesafe" : "openrouter") && <p className="inspector-warn" role="note"><b>{engine === "jev" ? "TypeSafe" : "OpenRouter"} is not connected.</b> Start needs its key. {onConnect && <button type="button" className="text-button" onClick={onConnect}>Connect {engine === "jev" ? "TypeSafe" : "OpenRouter"}</button>}</p>}
      <p className="inspector-hint">{engineInfo[engine].line}{engine !== "llm" && <> Uses your <b>{engineInfo[engine].via}</b> key from Connections.</>}{!decides && " Jev and Mercury Decide work with Capability, Composite and Custom classifier."}</p>
    </div>
    {jev ? <>
      {algorithm !== "llm_classifier" ? <div className="inspector-block">
        <label className="cutoff-label"><span className="field-label">Decision cutoff</span><output>{jev.cutoff.toFixed(2)}</output>
          <input type="range" aria-label="Decision cutoff" min="0" max="1" step="0.01" value={jev.cutoff} onChange={(event) => change({ jevClassifier: { ...jev, cutoff: Number(event.target.value) } })} /></label>
        <CutoffMeter cutoff={jev.cutoff} />
        <p className="inspector-hint">Raise it to send fewer tasks to Capable. {algorithm === "composite" ? "Composite's default is 0.92." : "Jev's library default is 0.60."} Calibrate on your own tasks.</p>
      </div> : <p className="inspector-hint">The decision model picks the target whose role description fits best. Each target needs a described role.</p>}
      <label className="slot-field"><span className="field-label">Decision instructions</span><textarea aria-label="Decision instructions" value={jev.instructions} placeholder="Leave empty for the default question." onChange={(event) => change({ jevClassifier: { ...jev, instructions: event.target.value } })} /></label>
    </> : <>
      <label className="slot-field"><span className="field-label">Model source</span>
        <select aria-label={`${title} source`} value={settings.judgeTarget ?? ""} onChange={(event) => change({ judgeTarget: event.target.value || null, judgeOptions: "" })}>
          <option value="">Separate model</option>{allTargets.map((target) => <option key={target.key} value={target.key}>Same model as {pretty(target.key)}</option>)}
        </select></label>
      {shared && <small className="field-hint">Uses the prompt, effort and options of {pretty(settings.judgeTarget!)}.</small>}
      <label className="slot-field"><span className="field-label">{title} prompt</span>
        <select aria-label="Classifier role" value={settings.classifierRoleId ?? classifierId} onChange={(event) => change({ classifierRoleId: event.target.value })}>
          {roles.filter((role) => role.kind === "classifier").map((role) => <option key={role.id} value={role.id}>{role.name}</option>)}
        </select></label>
    </>}
    {decides && <div className="inspector-block"><span className="field-label">{title} runs on</span>
      <Segmented label="Classification trigger" value={(settings.classifyTrigger ?? "every_request") as "every_request" | "user_turn" | "new_session"} onChange={(classifyTrigger) => change({ classifyTrigger })}
        options={[{ value: "every_request" as const, label: "Request", disabled: algorithm === "composite", hint: algorithm === "composite" ? "Composite decides per user turn or session." : undefined }, { value: "user_turn" as const, label: "User turn" }, { value: "new_session" as const, label: "Session" }]} />
    </div>}
    {algorithm === "llm_classifier" && <label className="slot-field"><span className="field-label">When the judge cannot decide</span><select aria-label="Fallback target" value={settings.defaultTarget || targets[0]?.key} onChange={(event) => change({ defaultTarget: event.target.value })}>
      {targets.map((target) => <option key={target.key} value={target.key}>Use {pretty(target.key)}</option>)}
    </select></label>}
    {algorithm === "advisor" && <label className="slot-field"><span className="field-label">Reviewer system prompt</span><textarea aria-label="Reviewer system prompt" value={settings.reviewerSystemPrompt ?? ""} onChange={(event) => change({ reviewerSystemPrompt: event.target.value })} placeholder="Leave empty to use the server's review contract, or write an APPROVE / REDO contract." /></label>}
    {!shared && !jev && <details className="inspector-more" open={!!settings.judgeOptions?.trim() || undefined}>
      <summary>More {title.toLowerCase()} options</summary>
      <label className="slot-field"><span className="field-label">Native options (TOML)</span><textarea aria-label="Judge native options (TOML)" value={settings.judgeOptions ?? ""} onChange={(event) => change({ judgeOptions: event.target.value })} placeholder={'reasoning_effort = "low"'} /></label>
    </details>}
    {onRemove && <button type="button" className="text-button danger" onClick={onRemove}>Remove judge</button>}
  </>;
}

/* ---------------------------------------------------------------- story */

function Story({ nameOf, story, beat, playing, onBeat, onPlay, label }: { nameOf: (key: string) => string; story: StoryBeat[]; beat: number | null; playing: boolean; onBeat: (index: number) => void; onPlay: () => void; label: string }) {
  const current = beat === null ? null : story[beat];
  return <section className="story" aria-label="Session walkthrough">
    <div className="story-head">
      <button type="button" className={`story-play${playing ? " playing" : ""}`} onClick={onPlay} aria-pressed={playing}>
        <span aria-hidden="true">{playing ? "❚❚" : "▶"}</span>{playing ? "Pause" : "Play a session"}
      </button>
      <p className={`story-why${current ? " shown" : ""}`} aria-live="polite">{current ? <><b>Step {beat! + 1}.</b> {current.why}</> : <><strong>How {label} handles a session.</strong> An illustration of the strategy's rule, not a prediction of real decisions.</>}</p>
    </div>
    <ol className="story-beats">
      {story.map((item, index) => <li key={index}>
        <button type="button" className={`story-beat ${item.kind}${beat === index ? " current" : ""}${beat !== null && index < beat ? " past" : ""}`} aria-pressed={beat === index} onClick={() => onBeat(index)}>
          <span className="beat-index">{index + 1}</span>
          <span className="beat-event"><small>{item.kind === "user" ? "User turn" : "Tool results"}</small>{item.event}</span>
          <span className="beat-route">{item.judge && <i className="beat-judge">judge</i>}{item.serves.length ? item.serves.map(nameOf).join(", ") : "no model"}{item.shadow?.map((key) => <i key={key} className="beat-shadow">+ {nameOf(key)} draft</i>)}</span>
          {beat === index && playing && <span className="beat-progress" aria-hidden="true" />}
        </button>
      </li>)}
    </ol>
  </section>;
}
