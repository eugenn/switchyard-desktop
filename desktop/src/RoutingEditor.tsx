import { useEffect, useState, type ReactNode } from "react";
import { algorithms, builtInRoles, servingTargets, validationMessage, type Algorithm, type ModelTarget, type RouteSettings, type RoutingRole } from "./api";

import { TypeSafeKey } from "./TypeSafeKey";

type Props = { settings: RouteSettings; change: (next: Partial<RouteSettings>) => void; disabled: boolean };
type AlgorithmInfo = (typeof algorithms)[number];
const classifierId = builtInRoles.find((role) => role.kind === "classifier")!.id;

const primaryStrategies: Algorithm[] = ["auto", "stage_router", "capability", "passthrough"];
const strategyGroups: { title: string; items: Algorithm[] }[] = [
  { title: "Judge-based", items: ["llm_classifier", "escalation", "composite", "advisor"] },
  { title: "Specialized", items: ["plan_execute", "vgr", "random", "prefill_router", "noop"] },
];
const decisionAlgorithms = ["capability", "llm_classifier", "composite"];
const optionalJudgeAlgorithms = ["stage_router", "plan_execute", "vgr"];

/** Changing strategy resets strategy-specific inputs; models in the pair fields and the role library stay. */
export function strategyReset(value: Algorithm): Partial<RouteSettings> {
  return { algorithm: value, classifyTrigger: value === "composite" ? "user_turn" : "every_request", targets: [], additionalTargets: [], nativeRouteOptions: "", judgeModel: "", judgeTarget: null, judgeOptions: "", jevClassifier: null, defaultTarget: "", reviewerSystemPrompt: "" };
}

function needs(algorithm: AlgorithmInfo) {
  const models = { pair: "2 models", variable: "2–6 models", single: "1 model", none: "No model" }[algorithm.shape];
  return algorithm.judge ? `${models} · judge` : models;
}

export function StrategyPicker({ settings, change, disabled }: Props) {
  const isPrimary = primaryStrategies.includes(settings.algorithm);
  const [more, setMore] = useState(!isPrimary);
  useEffect(() => { if (!isPrimary) setMore(true); }, [isPrimary]);
  const option = (value: Algorithm, compact = false) => {
    const algorithm = algorithms.find((item) => item.value === value)!;
    const active = settings.algorithm === value;
    return <label key={value} className={`strategy-option${compact ? " compact" : ""}${active ? " active" : ""}`}>
      <input type="radio" name="algorithm" value={value} checked={active} onChange={() => change(strategyReset(value))} />
      <span className="strategy-text">
        <strong>{algorithm.label}{value === "auto" && <em className="badge">Recommended</em>}</strong>
        <small>{algorithm.description}</small>
      </span>
      <span className="strategy-needs">{needs(algorithm)}</span>
    </label>;
  };
  return <fieldset disabled={disabled} className="strategy-picker">
    <legend className="sr-only">Routing strategy</legend>
    <div className="strategy-grid">{primaryStrategies.map((value) => option(value))}</div>
    <button type="button" className="disclosure" aria-expanded={more} onClick={() => setMore(!more)} disabled={!isPrimary && more}>
      <span aria-hidden="true">{more ? "−" : "+"}</span>{more ? "Fewer strategies" : `More strategies (${strategyGroups.reduce((sum, group) => sum + group.items.length, 0)})`}
    </button>
    {more && <div className="strategy-more">{strategyGroups.map((group) => <div key={group.title} className="strategy-group">
      <span className="group-title">{group.title}</span>{group.items.map((value) => option(value, true))}
    </div>)}</div>}
  </fieldset>;
}

export function RoutingEditor({ settings, change, disabled }: Props) {
  const algorithm = algorithms.find((item) => item.value === settings.algorithm)!;
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
  const addTarget = (additional: boolean) => {
    let suffix = 1;
    while (allTargets.some((target) => target.key === `target_${suffix}`)) suffix++;
    const target = { key: `target_${suffix}`, model: "", roleId: null, nativeOptions: "" };
    change(additional ? { additionalTargets: [...(settings.additionalTargets ?? []), target] } : { targets: [...targets, target] });
  };
  const label = (index: number) => variable ? `Target ${index + 1}` : algorithm.shape === "single" ? "Main" : index === 0 ? "Efficient" : "Capable";
  const decides = decisionAlgorithms.includes(settings.algorithm);
  const optionalJudge = !algorithm.judge && optionalJudgeAlgorithms.includes(settings.algorithm);
  const [judgeAdded, setJudgeAdded] = useState(false);
  const judgeInUse = !!settings.judgeModel || !!settings.judgeTarget || judgeAdded;
  const showJudge = !settings.jevClassifier && (algorithm.judge || (optionalJudge && judgeInUse));
  const removeJudge = () => { setJudgeAdded(false); change({ judgeModel: "", judgeTarget: null, judgeOptions: "" }); };
  const jev = settings.jevClassifier;

  return <fieldset disabled={disabled} className="routing-editor">
    <legend className="sr-only">Routing configuration</legend>
    {targets.length === 0 ? <p className="quiet-note">No-op answers without calling a model. Nothing to assign.</p> : <div className="model-table">
      <div className="model-head" aria-hidden="true"><span /><span>Model ID</span><span>Role</span><span /></div>
      {targets.map((target, index) => <TargetRow key={index} target={target} label={label(index)} tone={variable ? "neutral" : index === 0 ? "efficient" : "capable"} roles={roles} editableKey={variable}
        onChange={(patch) => updateTarget(index, patch)}
        onRemove={variable && targets.length > 2 ? () => change({ targets: targets.filter((_, position) => position !== index) }) : undefined} />)}
      {showJudge && <JudgeRow settings={settings} change={change} roles={roles} allTargets={allTargets} optional={!algorithm.judge} onRemove={optionalJudge ? removeJudge : undefined} />}
    </div>}
    {((variable && targets.length < 6) || (optionalJudge && !showJudge && !settings.jevClassifier)) && <div className="add-row">
      {variable && targets.length < 6 && <button type="button" className="add-button" onClick={() => addTarget(false)}><span aria-hidden="true">+</span>Add routing target</button>}
      {optionalJudge && !showJudge && <button type="button" className="add-button" onClick={() => setJudgeAdded(true)}><span aria-hidden="true">+</span>Add optional judge</button>}
    </div>}

    {settings.algorithm === "prefill_router" && <div className="inline-block"><p className="editor-warning">Optional server feature. The bundled server does not include prefill inference, and there is no silent fallback.</p>
      <label>Checkpoint path<input value={settings.checkpoint ?? ""} onChange={(event) => change({ checkpoint: event.target.value })} /></label></div>}

    {(decides || settings.algorithm === "llm_classifier" || settings.algorithm === "advisor") && <div className="inline-block decision">
      <h3>How the decision is made</h3>
      {decides && <label className="switch-line"><input type="checkbox" checked={!!jev} onChange={(event) => change({ jevClassifier: event.target.checked ? { modelID: "jev-latest", cutoff: 0.6, instructions: "" } : null, judgeModel: "", judgeTarget: null, judgeOptions: "", nativeRouteOptions: "" })} />
        <span>Use Jev / TypeSafe instead of an LLM judge</span></label>}
      {jev && <div className="field-grid">
        <label>Jev model<input value={jev.modelID} onChange={(event) => change({ jevClassifier: { ...jev, modelID: event.target.value } })} /></label>
        {settings.algorithm !== "llm_classifier" && <label>Decision cutoff<input type="number" min="0" max="1" step="0.05" value={jev.cutoff} onChange={(event) => change({ jevClassifier: { ...jev, cutoff: Number(event.target.value) } })} /></label>}
        <label className="wide">Decision instructions<textarea value={jev.instructions} onChange={(event) => change({ jevClassifier: { ...jev, instructions: event.target.value } })} /></label>
        <div className="wide"><TypeSafeKey disabled={disabled} /></div>
      </div>}
      <div className="field-grid">
        {decides && <label>Classification trigger<select value={settings.classifyTrigger ?? "every_request"} onChange={(event) => change({ classifyTrigger: event.target.value })}>
          {settings.algorithm !== "composite" && <option value="every_request">Every request</option>}<option value="user_turn">User turn</option><option value="new_session">New session</option>
        </select></label>}
        {settings.algorithm === "llm_classifier" && <label>Fallback target<select value={settings.defaultTarget || targets[0]?.key} onChange={(event) => change({ defaultTarget: event.target.value })}>
          {targets.map((target) => <option key={target.key} value={target.key}>{target.key}</option>)}
        </select></label>}
        {settings.algorithm === "advisor" && <label className="wide">Reviewer system prompt<textarea value={settings.reviewerSystemPrompt ?? ""} onChange={(event) => change({ reviewerSystemPrompt: event.target.value })} placeholder="Leave empty to use the server's review contract, or write an APPROVE / REDO contract." /></label>}
      </div>
    </div>}
  </fieldset>;
}

function JudgeRow({ settings, change, roles, allTargets, optional, onRemove }: { settings: RouteSettings; change: Props["change"]; roles: RoutingRole[]; allTargets: ModelTarget[]; optional: boolean; onRemove?: () => void }) {
  const [open, setOpen] = useState(false);
  const shared = !!settings.judgeTarget;
  return <div className={`model-row judge${open ? " open" : ""}`}>
    <div className="model-row-main">
      <span className="row-tag judge">Judge{optional && <small>optional</small>}</span>
      <div className="judge-source">
        <select aria-label="Judge source" value={settings.judgeTarget ?? ""} onChange={(event) => change({ judgeTarget: event.target.value || null, judgeOptions: "" })}>
          <option value="">Separate model</option>{allTargets.map((target) => <option key={target.key} value={target.key}>Same as {target.key}</option>)}
        </select>
        {!shared && <input aria-label="Judge model" autoComplete="off" spellCheck={false} list="account-models" placeholder="Judge model ID" value={settings.judgeModel ?? ""} onChange={(event) => change({ judgeModel: event.target.value })} />}
      </div>
      <select aria-label="Classifier role" value={settings.classifierRoleId ?? classifierId} onChange={(event) => change({ classifierRoleId: event.target.value })}>
        {roles.filter((role) => role.kind === "classifier").map((role) => <option key={role.id} value={role.id}>{role.name}</option>)}
      </select>
      <button type="button" className="row-more" aria-expanded={open} aria-label="Judge options" onClick={() => setOpen(!open)}>⋯</button>
    </div>
    {shared && <p className="row-role">Uses the prompt, effort and native options of {settings.judgeTarget}.</p>}
    {open && <div className="row-options">
      {!shared && <label>Judge native options (TOML)<textarea value={settings.judgeOptions ?? ""} onChange={(event) => change({ judgeOptions: event.target.value })} placeholder={'reasoning_effort = "low"'} /></label>}
      {onRemove && <button type="button" className="text-button danger" onClick={onRemove}>Remove judge</button>}
    </div>}
  </div>;
}

function TargetRow({ target, roles, label, tone, editableKey, onChange, onRemove }: {
  target: ModelTarget; roles: RoutingRole[]; label: string; tone: string; editableKey?: boolean;
  onChange: (patch: Partial<ModelTarget>) => void; onRemove?: () => void;
}) {
  const [open, setOpen] = useState(false);
  const role = roles.find((item) => item.id === target.roleId);
  const hasOptions = !!target.nativeOptions.trim();
  return <div className={`model-row${open ? " open" : ""}`}>
    <div className="model-row-main">
      <span className={`row-tag ${tone}`}>{label}{editableKey && <small>{target.key}</small>}</span>
      <input aria-label={`${label} model`} autoComplete="off" spellCheck={false} list="account-models" placeholder="Model ID" value={target.model} onChange={(event) => onChange({ model: event.target.value })} />
      <select aria-label={`${label} role`} value={target.roleId ?? ""} onChange={(event) => onChange({ roleId: event.target.value || null })}><option value="">No role</option>
        {roles.filter((item) => item.kind === "target").map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}
      </select>
      <button type="button" className={`row-more${hasOptions ? " has-value" : ""}`} aria-expanded={open} aria-label={`${label} options`} onClick={() => setOpen(!open)}>⋯</button>
    </div>
    {role && <p className="row-role"><b>{role.effort ?? "default"} effort</b> {role.text}</p>}
    {open && <div className="row-options">
      {editableKey && <label>Target key<input value={target.key} onChange={(event) => onChange({ key: event.target.value })} /></label>}
      <label>Native target options (TOML)<textarea value={target.nativeOptions} onChange={(event) => onChange({ nativeOptions: event.target.value })} placeholder={'reasoning_effort = "high"\nsystem_prompt = "Follow the repository instructions."'} /></label>
      <small>Overrides the role. Cannot change id or llm_client.</small>
      {onRemove && <button type="button" className="text-button danger" onClick={onRemove}>Remove {label.toLowerCase()}</button>}
    </div>}
  </div>;
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
        {(settings.additionalTargets ?? []).length > 0 && <div className="model-table">{settings.additionalTargets!.map((target, index) => <TargetRow key={index} target={target} label={`Extra ${index + 1}`} tone="neutral" roles={roles} editableKey
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
