import { useEffect, useState, type ReactNode } from "react";
import { algorithms, builtInRoles, servingTargets, validationMessage, type Algorithm, type ModelTarget, type RouteSettings, type RoutingRole } from "./api";
import { families, guides, variableJob } from "./routingGuide";
import { TypeSafeKey } from "./TypeSafeKey";

type Props = { settings: RouteSettings; change: (next: Partial<RouteSettings>) => void; disabled: boolean };
const classifierId = builtInRoles.find((role) => role.kind === "classifier")!.id;
const decisionAlgorithms = ["capability", "llm_classifier", "composite"];
const optionalJudgeAlgorithms = ["stage_router", "plan_execute", "vgr"];
const modelPattern = /^[a-zA-Z0-9._:/-]{1,200}$/;

/** Changing strategy resets strategy-specific inputs; models in the pair fields and the role library stay. */
export function strategyReset(value: Algorithm): Partial<RouteSettings> {
  return { algorithm: value, classifyTrigger: value === "composite" ? "user_turn" : "every_request", targets: [], additionalTargets: [], nativeRouteOptions: "", judgeModel: "", judgeTarget: null, judgeOptions: "", jevClassifier: null, defaultTarget: "", reviewerSystemPrompt: "" };
}

/** The chosen strategy in one line, with the full grouped list one click away. */
export function StrategyPicker({ settings, disabled, onPick }: { settings: RouteSettings; disabled: boolean; onPick: (value: Algorithm) => void }) {
  const [open, setOpen] = useState(false);
  useEffect(() => { if (disabled) setOpen(false); }, [disabled]);
  const current = algorithms.find((item) => item.value === settings.algorithm)!;
  const guide = guides[settings.algorithm];
  const group = (id: string) => {
    const family = families.find((item) => item.id === id)!;
    return <div key={family.id} className={`strategy-group ${family.id}`}>
      <span className="group-title">{family.title}</span>
      {algorithms.filter((item) => guides[item.value].family === family.id).map((item) => {
        const active = item.value === settings.algorithm;
        return <label key={item.value} className={`strategy-option${active ? " active" : ""}`}>
          <input type="radio" name="algorithm" value={item.value} checked={active} onChange={() => { onPick(item.value); setOpen(false); }} />
          <span className="strategy-text"><strong>{item.label}{item.value === "auto" && <em className="badge">Recommended</em>}{item.value === "prefill_router" && <em className="badge muted">Not in bundled server</em>}</strong><small>{guides[item.value].tagline}</small></span>
          <span className="strategy-needs">{guides[item.value].needs}</span>
        </label>;
      })}
    </div>;
  };
  return <section className={`strategy-section${open ? " open" : ""}`} aria-label="Strategy">
    <div className="strategy-summary">
      {open ? <div className="strategy-current">
        <span className="section-label">Strategy</span>
        <strong>Choose how requests pick a model</strong>
        <p>Current: {current.label}. Most people should keep Auto.</p>
      </div> : <div className="strategy-current">
        <span className="section-label">Strategy</span>
        <strong>{current.label}{current.value === "auto" && <em className="badge">Recommended</em>}</strong>
        <p>{guide.tagline}</p>
        <RouteStrip settings={settings} />
        <ul className="strategy-facts" aria-label="What this strategy needs">
          <li>{guide.needs}</li><li>{guide.cost}</li>
        </ul>
      </div>}
      <button type="button" className="button secondary small" aria-expanded={open} disabled={disabled} onClick={() => setOpen(!open)}>{open ? "Close" : "Change strategy"}</button>
    </div>
    {open && <fieldset disabled={disabled} className="strategy-list">
      <legend className="sr-only">Routing strategy</legend>
      {group("recommended")}
      <div className="strategy-column">{group("judge")}</div>
      <div className="strategy-column">{group("signals")}{group("other")}</div>
      <p className="quiet-note">Switching keeps your Efficient and Capable models and your roles. Judge, extra targets and route TOML are reset, and you can undo the switch.</p>
    </fieldset>}
  </section>;
}

type Step = { text: string } | { slot: "efficient" | "capable" | "judge" | "neutral"; title: string; model?: string; note?: string } | { join: string };
const pretty = (key: string) => key === "efficient" ? "Efficient" : key === "capable" ? "Capable" : key;

/** A one-line picture of where a request goes in the chosen strategy, with the models filled in so far. */
function RouteStrip({ settings }: { settings: RouteSettings }) {
  const targets = servingTargets(settings);
  const efficient: Step = { slot: "efficient", title: "Efficient", model: targets[0]?.model };
  const capable: Step = { slot: "capable", title: "Capable", model: targets[1]?.model };
  const judgeModel = settings.jevClassifier ? "Jev" : settings.judgeTarget ? `same as ${pretty(settings.judgeTarget)}` : settings.judgeModel;
  const judge = (title = "Judge"): Step => ({ slot: "judge", title, model: judgeModel });
  const hasJudge = !!settings.judgeModel || !!settings.judgeTarget;
  const pool: Step[] = targets.flatMap((target, index) => [...(index ? [{ join: "·" }] : []), { slot: "neutral" as const, title: target.key, model: target.model }]);
  const to = { join: "→" }, or = { join: "or" };
  const steps: Step[] = {
    auto: [{ text: "Tool results" }, to, efficient, or, capable],
    stage_router: [{ text: "Tool results" }, ...(hasJudge ? [{ join: "+" }, judge()] : []), to, efficient, or, capable],
    plan_execute: [{ ...capable, note: "plans" }, { join: "then" }, { ...efficient, note: "carries out" }],
    capability: [judge(), to, efficient, or, capable],
    composite: [judge(), to, efficient, or, capable, { text: "tool results can move up" }],
    escalation: [efficient, to, { ...judge(), note: "checks" }, to, { ...capable, note: "after repeated failure" }],
    llm_classifier: [judge(), to, ...pool],
    advisor: [{ slot: "efficient", title: "Executor", model: targets[0]?.model }, to, { ...judge("Advisor"), note: "reviews" }],
    passthrough: [{ slot: "efficient", title: "Model", model: targets[0]?.model }],
    random: [{ text: "Random split" }, to, ...pool],
    vgr: [{ ...capable, note: "answers" }, { join: "while" }, { ...efficient, note: "drafts in shadow" }],
    prefill_router: [{ text: "Checkpoint" }, to, ...pool],
    noop: [{ text: "Answers OK, no model" }],
  }[settings.algorithm] as Step[];
  return <p className="route-strip" aria-label="How a request is routed">
    <span className="route-source">Request</span><i className="route-join">→</i>
    {steps.map((step, index) => "join" in step ? <i key={index} className="route-join">{step.join}</i>
      : "text" in step ? <span key={index} className="route-text">{step.text}</span>
      : <span key={index} className={`route-chip ${step.slot}`}><b>{step.title}</b>{step.note && <small>{step.note}</small>}<code className={step.model ? "" : "missing"}>{step.model || "no model yet"}</code></span>)}
  </p>;
}

/** Model cards for the chosen strategy, then the judge that decides between them. */
export function RoutingEditor({ settings, change, disabled }: Props) {
  const algorithm = algorithms.find((item) => item.value === settings.algorithm)!;
  const guide = guides[settings.algorithm];
  const roles = settings.roles ?? builtInRoles;
  const targets = servingTargets(settings);
  const allTargets = [...targets, ...(settings.additionalTargets ?? [])];
  const variable = algorithm.shape === "variable";
  const updateTarget = (index: number, patch: Partial<ModelTarget>) => {
    if (variable || settings.targets?.length) {
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
    change({ targets: [...targets, { key: `target_${suffix}`, model: "", roleId: null, nativeOptions: "" }] });
  };
  const slot = (index: number) => variable ? { title: `Target ${index + 1}`, job: variableJob(settings.algorithm) } : guide.slots[index] ?? { title: `Target ${index + 1}`, job: "" };
  const tone = (index: number) => variable ? "neutral" : algorithm.shape === "single" ? "efficient" : index === 0 ? "efficient" : "capable";
  const classifier = settings.algorithm === "llm_classifier" && !settings.nativeRouteOptions?.trim();
  const roleNeed = classifier ? "required: the judge reads it" : algorithm.judge ? "optional: the judge reads its description" : "optional: sets effort and prompt";
  const optionalJudge = !algorithm.judge && optionalJudgeAlgorithms.includes(settings.algorithm);
  const [judgeAdded, setJudgeAdded] = useState(false);
  const judgeInUse = !!settings.judgeModel || !!settings.judgeTarget || judgeAdded;
  const showDecision = algorithm.judge || (optionalJudge && judgeInUse);
  const removeJudge = () => { setJudgeAdded(false); change({ judgeModel: "", judgeTarget: null, judgeOptions: "" }); };

  return <fieldset disabled={disabled} className="routing-editor">
    <legend className="sr-only">Routing configuration</legend>
    {targets.length === 0 ? <p className="slots-empty">No-op answers OK without calling a model, so there is nothing to assign.</p>
      : <div className={`slot-grid${variable ? " many" : ""}${targets.length === 1 ? " single" : ""}`}>
        {targets.map((target, index) => {
          const described = roles.some((role) => role.id === target.roleId && role.kind === "target" && role.text.trim());
          return <SlotCard key={index} target={target} roles={roles} title={slot(index).title} job={slot(index).job} tone={tone(index)} editableKey={variable} roleNeed={roleNeed}
            roleMissing={classifier && !described}
            onChange={(patch) => updateTarget(index, patch)}
            onRemove={variable && targets.length > 2 ? () => change({ targets: targets.filter((_, position) => position !== index) }) : undefined} />;
        })}
        {variable && targets.length < 6 && <button type="button" className="add-slot" aria-label="Add routing target" onClick={addTarget}><span aria-hidden="true">+</span>Add routing target<small>{targets.length} of 6</small></button>}
      </div>}

    {settings.algorithm === "prefill_router" && <div className="inline-block"><p className="editor-warning">Optional server feature. The bundled server does not include prefill inference, and there is no silent fallback.</p>
      <label>Checkpoint path<input value={settings.checkpoint ?? ""} onChange={(event) => change({ checkpoint: event.target.value })} /></label></div>}

    {showDecision && <DecisionCard settings={settings} change={change} roles={roles} targets={targets} allTargets={allTargets} disabled={disabled} onRemove={optionalJudge ? removeJudge : undefined} />}
    {optionalJudge && !showDecision && <button type="button" className="add-judge" onClick={() => setJudgeAdded(true)}>
      <span aria-hidden="true">+</span><span><strong>Add optional judge</strong><small>{guide.judge?.job.replace(/^Optional\. /, "")}</small></span>
    </button>}
  </fieldset>;
}

function DecisionCard({ settings, change, roles, targets, allTargets, disabled, onRemove }: { settings: RouteSettings; change: Props["change"]; roles: RoutingRole[]; targets: ModelTarget[]; allTargets: ModelTarget[]; disabled: boolean; onRemove?: () => void }) {
  const algorithm = settings.algorithm;
  const judge = guides[algorithm].judge ?? { title: "Judge", job: "" };
  const decides = decisionAlgorithms.includes(algorithm);
  const jev = settings.jevClassifier;
  const shared = !!settings.judgeTarget;
  const judgeMissing = !jev && !shared && !modelPattern.test(settings.judgeModel ?? "");
  const customised = !!settings.judgeOptions?.trim();
  return <section className={`decision-card${judgeMissing && settings.judgeModel ? " invalid" : ""}`} aria-label={judge.title}>
    <header>
      <span className="slot-name">{judge.title}{onRemove && <small>optional</small>}</span>
      <p className="slot-job">{judge.job}</p>
    </header>
    {jev ? <div className="field-grid">
      <label>Jev model<input value={jev.modelID} onChange={(event) => change({ jevClassifier: { ...jev, modelID: event.target.value } })} /></label>
      {algorithm !== "llm_classifier" && <label>Decision cutoff<input type="number" min="0" max="1" step="0.05" value={jev.cutoff} onChange={(event) => change({ jevClassifier: { ...jev, cutoff: Number(event.target.value) } })} /></label>}
      <label className="wide">Decision instructions<textarea value={jev.instructions} onChange={(event) => change({ jevClassifier: { ...jev, instructions: event.target.value } })} /></label>
      <div className="wide"><TypeSafeKey disabled={disabled} /></div>
    </div> : <div className="field-grid">
      <div className="slot-field wide">
        <span className="field-label">{judge.title} model</span>
        <div className="judge-source">
          <select aria-label={`${judge.title} source`} value={settings.judgeTarget ?? ""} onChange={(event) => change({ judgeTarget: event.target.value || null, judgeOptions: "" })}>
            <option value="">Separate model</option>{allTargets.map((target) => <option key={target.key} value={target.key}>Same model as {pretty(target.key)}</option>)}
          </select>
          {!shared && <input aria-label={`${judge.title} model`} aria-invalid={judgeMissing} autoComplete="off" spellCheck={false} list="account-models" placeholder="Judge model ID" value={settings.judgeModel ?? ""} onChange={(event) => change({ judgeModel: event.target.value })} />}
        </div>
        {shared ? <small className="field-hint">Uses the prompt, effort and options of {pretty(settings.judgeTarget!)}.</small>
          : judgeMissing && settings.judgeModel ? <small className="field-issue">Use the exact model ID: letters, digits and . _ : / - only.</small>
          : !settings.judgeModel && <small className="field-hint">A fast model that reliably returns JSON works best.</small>}
      </div>
    </div>}
    <div className="field-grid">
      {!jev && <label className="slot-field"><span className="field-label">{judge.title} prompt</span>
        <select aria-label="Classifier role" value={settings.classifierRoleId ?? classifierId} onChange={(event) => change({ classifierRoleId: event.target.value })}>
          {roles.filter((role) => role.kind === "classifier").map((role) => <option key={role.id} value={role.id}>{role.name}</option>)}
        </select></label>}
      {decides && <label className="slot-field"><span className="field-label">{judge.title} runs on</span><select aria-label="Classification trigger" value={settings.classifyTrigger ?? "every_request"} onChange={(event) => change({ classifyTrigger: event.target.value })}>
        {algorithm !== "composite" && <option value="every_request">Every request</option>}<option value="user_turn">Each user turn</option><option value="new_session">Once per session</option>
      </select></label>}
      {algorithm === "llm_classifier" && <label className="slot-field"><span className="field-label">When the judge cannot decide</span><select aria-label="Fallback target" value={settings.defaultTarget || targets[0]?.key} onChange={(event) => change({ defaultTarget: event.target.value })}>
        {targets.map((target) => <option key={target.key} value={target.key}>Use {pretty(target.key)}</option>)}
      </select></label>}
      {algorithm === "advisor" && <label className="slot-field wide"><span className="field-label">Reviewer system prompt</span><textarea aria-label="Reviewer system prompt" value={settings.reviewerSystemPrompt ?? ""} onChange={(event) => change({ reviewerSystemPrompt: event.target.value })} placeholder="Leave empty to use the server's review contract, or write an APPROVE / REDO contract." /></label>}
    </div>
    {decides && <label className="switch-line"><input type="checkbox" aria-label="Use Jev / TypeSafe instead of an LLM judge" checked={!!jev} onChange={(event) => change({ jevClassifier: event.target.checked ? { modelID: "jev-latest", cutoff: 0.6, instructions: "" } : null, judgeModel: "", judgeTarget: null, judgeOptions: "", nativeRouteOptions: "" })} />
      <span>Use Jev / TypeSafe instead of an LLM judge<small>An external classifier service in place of a judge model. It needs a TypeSafe API key.</small></span></label>}
    {((!shared && !jev) || onRemove) && <details className="card-more" open={customised || undefined}>
      <summary>More {judge.title.toLowerCase()} options</summary>
      {!shared && !jev && <label className="slot-field"><span className="field-label">Native options (TOML)</span><textarea aria-label="Judge native options (TOML)" value={settings.judgeOptions ?? ""} onChange={(event) => change({ judgeOptions: event.target.value })} placeholder={'reasoning_effort = "low"'} /></label>}
      {onRemove && <button type="button" className="text-button danger" onClick={onRemove}>Remove judge</button>}
    </details>}
  </section>;
}

function SlotCard({ target, roles, title, job, tone, editableKey, roleNeed, roleMissing, onChange, onRemove }: {
  target: ModelTarget; roles: RoutingRole[]; title: string; job: string; tone: string; editableKey?: boolean; roleNeed: string; roleMissing?: boolean;
  onChange: (patch: Partial<ModelTarget>) => void; onRemove?: () => void;
}) {
  const role = roles.find((item) => item.id === target.roleId);
  const customised = !!target.nativeOptions.trim();
  const empty = !target.model.trim();
  const invalid = !modelPattern.test(target.model);
  return <section className={`slot-card ${tone}${(invalid && !empty) || roleMissing ? " invalid" : ""}`} aria-label={title}>
    <header>
      <span className="slot-name">{title}</span>
      {editableKey && <code className="slot-key">{target.key}</code>}
    </header>
    {job && <p className="slot-job">{job}</p>}
    <div className="slot-fields">
      <label className="slot-field"><span className="field-label">Model ID</span>
        <input aria-label={`${title} model`} aria-invalid={invalid} autoComplete="off" spellCheck={false} list="account-models" placeholder="Model ID" value={target.model} onChange={(event) => onChange({ model: event.target.value })} /></label>
      <label className="slot-field"><span className="field-label" title={roleNeed}>Role <small>{roleNeed.split(":")[0]}</small></span>
        <select aria-label={`${title} role`} aria-invalid={roleMissing} value={target.roleId ?? ""} onChange={(event) => onChange({ roleId: event.target.value || null })}><option value="">No role</option>
          {roles.filter((item) => item.kind === "target").map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}
        </select></label>
    </div>
    {invalid && !empty && <small className="field-issue">Use the exact model ID: letters, digits and . _ : / - only.</small>}
    {role ? <p className="row-role"><b>{role.effort ?? "default"} effort</b> {role.text}</p> : roleMissing ? <small className="field-issue">Pick a role with a description: the judge reads it to choose this target.</small>
      : <small className="field-hint">{roleNeed.split(": ")[1]?.replace(/^./, (letter) => letter.toUpperCase())}.</small>}
    <details className="card-more" open={customised || undefined}>
      <summary>{customised ? "Custom options set" : "More options"}</summary>
      {editableKey && <label className="slot-field"><span className="field-label">Target key</span><input aria-label="Target key" value={target.key} onChange={(event) => onChange({ key: event.target.value })} /></label>}
      <label className="slot-field"><span className="field-label">Native target options (TOML)</span><textarea aria-label={`${title} native options (TOML)`} value={target.nativeOptions} onChange={(event) => onChange({ nativeOptions: event.target.value })} placeholder={'reasoning_effort = "high"\nsystem_prompt = "Follow the repository instructions."'} /></label>
      <small className="field-hint">Overrides the role. Cannot change id or llm_client.</small>
      {onRemove && <button type="button" className="text-button danger" onClick={onRemove}>Remove {title.toLowerCase()}</button>}
    </details>
  </section>;
}

export function AdvancedSettings({ settings, change, disabled }: Props) {
  const roles = settings.roles ?? builtInRoles;
  const allTargets = [...servingTargets(settings), ...(settings.additionalTargets ?? [])];
  const addAdditional = () => {
    let suffix = 1;
    while (allTargets.some((target) => target.key === `target_${suffix}`)) suffix++;
    change({ additionalTargets: [...(settings.additionalTargets ?? []), { key: `target_${suffix}`, model: "", roleId: null, nativeOptions: "" }] });
  };
  const nativeType = ["capability", "escalation", "llm_classifier"].includes(settings.algorithm) ? "llm_classifier" : settings.algorithm === "plan_execute" ? "stage_router" : settings.algorithm;
  const customised = !!settings.nativeRouteOptions?.trim() || (settings.additionalTargets?.length ?? 0) > 0;
  return <details className="advanced" open={customised || undefined}>
    <summary><span>Advanced</span><small>Context limits, extra targets, route TOML</small></summary>
    <fieldset disabled={disabled} className="advanced-body"><legend className="sr-only">Advanced routing settings</legend>
      <Group title="Context and capabilities" hint="Load account models to fill these, or set them yourself. Do not advertise a window or image input that any selectable model cannot serve.">
        <label>Context window (tokens)<input type="number" min="1024" max="100000000" value={settings.contextWindow ?? ""} placeholder="Model default" onChange={(event) => change({ contextWindow: event.target.value ? Number(event.target.value) : null })} /></label>
        <label className="switch-line"><input type="checkbox" checked={settings.allowsLongContext ?? true} onChange={(event) => change({ allowsLongContext: event.target.checked })} /><span>Allow context over 272,000 tokens</span></label>
        <label className="switch-line"><input type="checkbox" checked={settings.vision ?? false} onChange={(event) => change({ vision: event.target.checked })} /><span>All selectable models support images</span></label>
        <label className="switch-line"><input type="checkbox" checked={settings.reasoningSummaries ?? true} onChange={(event) => change({ reasoningSummaries: event.target.checked })} /><span>Keep Codex reasoning summaries</span></label>
      </Group>
      <Group title="Additional targets" hint="Available to native policies and sub-agents. They are not added to the main model list.">
        {(settings.additionalTargets ?? []).length > 0 && <div className="slot-grid many">{settings.additionalTargets!.map((target, index) => <SlotCard key={index} target={target} title={`Extra ${index + 1}`} job="Available to native policies and sub-agents." roleNeed="optional: sets effort and prompt" tone="neutral" roles={roles} editableKey
          onChange={(patch) => change({ additionalTargets: settings.additionalTargets!.map((item, position) => position === index ? { ...item, ...patch } : item) })}
          onRemove={() => change({ additionalTargets: settings.additionalTargets!.filter((_, position) => position !== index) })} />)}</div>}
        {(settings.additionalTargets?.length ?? 0) < 30 && <button type="button" className="add-button" onClick={addAdditional}><span aria-hidden="true">+</span>Add additional target</button>}
      </Group>
      <Group title="Native route body (TOML)" hint="Replaces the whole strategy body, it is not merged. Omit id and keep the selected server type; nested tables use [routes.main.…]. Clear it to return to the preset. The server validates it on start.">
        <textarea aria-label="Native route body (TOML)" className="native-options" value={settings.nativeRouteOptions ?? ""} onChange={(event) => change({ nativeRouteOptions: event.target.value })} placeholder={`type = "${nativeType}"`} />
      </Group>
    </fieldset>
  </details>;
}

function Group({ title, hint, children }: { title: string; hint: string; children: ReactNode }) {
  return <section className="advanced-group"><h4>{title}</h4><p className="quiet-note">{hint}</p>{children}</section>;
}

export function RolesEditor({ settings, change, disabled }: Props) {
  const roles = settings.roles ?? builtInRoles;
  const groups = settings.roleGroups ?? [];
  const [search, setSearch] = useState("");
  const [groupFilter, setGroupFilter] = useState("");
  const [selectedId, setSelectedId] = useState<string | undefined>(roles[0]?.id);
  const selected = roles.find((role) => role.id === selectedId);
  const update = (patch: Partial<RoutingRole>) => change({ roles: roles.map((role) => role.id === selectedId ? { ...role, ...patch } : role) });
  const add = (duplicate = false) => {
    const role: RoutingRole = duplicate && selected ? { ...selected, id: crypto.randomUUID(), name: `${selected.name} copy`, isBuiltIn: false } :
      { id: crypto.randomUUID(), kind: "target", name: "New role", text: "", tags: [], groupIDs: [], isBuiltIn: false };
    change({ roles: [...roles, role] }); setSelectedId(role.id);
  };
  const assigned = (id: string) => settings.efficientRoleId === id || settings.capableRoleId === id ||
    (settings.classifierRoleId ?? classifierId) === id || [...(settings.targets ?? []), ...(settings.additionalTargets ?? [])].some((target) => target.roleId === id);
  return <section className="panel roles-panel"><div className="panel-heading"><div><h2>Role library</h2><p>{builtInRoles.length} built-in roles plus your own prompts. Assign them to models on the Routing page.</p></div></div>
    <fieldset disabled={disabled} className="roles-editor"><legend className="sr-only">Role library</legend>
      <div className="role-toolbar"><label>Search roles<input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Name, prompt or tag" /></label>
        <label>Filter group<select value={groupFilter} onChange={(event) => setGroupFilter(event.target.value)}><option value="">All groups</option>{groups.map((group) => <option key={group.id} value={group.id}>{group.name}</option>)}</select></label>
        <button className="button secondary" onClick={() => add()}>New role</button></div>
      <div className="role-library-grid"><div className="role-list">{roles.filter((role) => (!groupFilter || role.groupIDs.includes(groupFilter)) && [role.name, role.text, role.systemPrompt ?? "", ...role.tags].join(" ").toLowerCase().includes(search.toLowerCase())).map((role) =>
        <button className={role.id === selectedId ? "active" : ""} key={role.id} onClick={() => setSelectedId(role.id)}>{role.name}<small>{role.kind} · {role.effort ?? "default"}</small></button>)}</div>
      {selected && <div className="role-detail"><label>Role name<input value={selected.name} onChange={(event) => update({ name: event.target.value })} /></label>
        <label>Role kind<select value={selected.kind} disabled={assigned(selected.id)} onChange={(event) => update({ kind: event.target.value as RoutingRole["kind"] })}><option value="target">Target description</option><option value="classifier">Classifier template</option></select></label>
        <label>{selected.kind === "classifier" ? "Classifier template (include {{targets}})" : "Routing description"}<textarea value={selected.text} onChange={(event) => update({ text: event.target.value })} /></label>
        {selected.kind === "target" && <label>Model system prompt<textarea value={selected.systemPrompt ?? ""} onChange={(event) => update({ systemPrompt: event.target.value || null })} /></label>}
        <label>Reasoning effort<select value={selected.effort ?? ""} onChange={(event) => update({ effort: event.target.value || null })}><option value="">Model default</option>{["low", "medium", "high", "xhigh", "max", "ultra"].map((effort) => <option key={effort}>{effort}</option>)}</select></label>
        <label>Tags<input value={selected.tags.join(", ")} onChange={(event) => update({ tags: event.target.value.split(",").map((tag) => tag.trim().toLowerCase()).filter(Boolean) })} /></label>
        <div className="group-memberships">{groups.map((group) => <label className="checkbox-label" key={group.id}><input type="checkbox" checked={selected.groupIDs.includes(group.id)} onChange={(event) => update({ groupIDs: event.target.checked ? [...selected.groupIDs, group.id] : selected.groupIDs.filter((id) => id !== group.id) })} />{group.name}</label>)}</div>
        <div className="role-toolbar"><button className="button secondary" onClick={() => add(true)}>Duplicate role</button>
          {builtInRoles.some((role) => role.id === selected.id) && <button className="button secondary" onClick={() => update({ ...builtInRoles.find((role) => role.id === selected.id)!, groupIDs: selected.groupIDs })}>Reset role</button>}
          <button className="button secondary" disabled={assigned(selected.id)} onClick={() => { change({ roles: roles.filter((role) => role.id !== selected.id) }); setSelectedId(roles.find((role) => role.id !== selected.id)?.id); }}>Delete role</button></div>
        {assigned(selected.id) && <small>Unassign this role before deleting it or changing its kind.</small>}
      </div>}</div>
      <details><summary>Project groups</summary><p className="editor-hint">Project paths are labels only: no folder is opened or used for automatic routing.</p>
        {groups.map((group) => <div className="editor-section" key={group.id}><label>Group name<input value={group.name} onChange={(event) => change({ roleGroups: groups.map((item) => item.id === group.id ? { ...item, name: event.target.value } : item) })} /></label>
          <label>Project path label<input value={group.projectPath} onChange={(event) => change({ roleGroups: groups.map((item) => item.id === group.id ? { ...item, projectPath: event.target.value } : item) })} /></label>
          <div className="role-toolbar"><button className="button secondary" disabled={!!validationMessage(settings)} onClick={() => {
            const profile = { ...settings, roleGroups: [], roles: roles.map((role) => ({ ...role, groupIDs: [] })) };
            change({ roleGroups: groups.map((item) => item.id === group.id ? { ...item, routingProfile: profile } : item) });
          }}>Save current setup to {group.name}</button>
          {group.routingProfile && <><button className="button secondary" onClick={() => change({ ...group.routingProfile!, roleGroups: groups, roles: [...roles, ...(group.routingProfile!.roles ?? []).filter((saved) => !roles.some((role) => role.id === saved.id))] })}>Load setup from {group.name}</button><button className="text-button" onClick={() => change({ roleGroups: groups.map((item) => item.id === group.id ? { ...item, routingProfile: null } : item) })}>Clear saved setup</button></>}
          </div>
          <button className="text-button" onClick={() => change({ roleGroups: groups.filter((item) => item.id !== group.id), roles: roles.map((role) => ({ ...role, groupIDs: role.groupIDs.filter((id) => id !== group.id) })) })}>Delete group</button></div>)}
        <button className="button secondary" onClick={() => change({ roleGroups: [...groups, { id: crypto.randomUUID(), name: `Project ${groups.length + 1}`, projectPath: "" }] })}>New group</button>
      </details>
    </fieldset>
  </section>;
}
