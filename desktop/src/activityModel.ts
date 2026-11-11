// Activity data model: pure functions over routing-log records and server stats.
import { builtInRoles, servingTargets, type RouteSettings } from "./api";

type Raw = Record<string, unknown>;

export interface Tokens { prompt: number; cached: number; cacheCreation: number; completion: number; reasoning: number; total: number }
export interface LogRecord {
  id: number; ts: number | null; model: string | null; tier: string | null; origin: string | null; sessionID: string | null;
  agentID: string | null; isDelegated: boolean; agentKind: string | null; agentRole: string | null; subagentIdentityUnsupported: boolean;
  route: string | null; tokens: Tokens; contextInputTokens: number | null; modelIdentity: string; isClassifier: boolean; raw: Raw;
}

// ---------- palette & formatting ----------

export const palette = ["#4FC98A", "#5598E7", "#D4B17D", "#A99BD4", "#6EB9B6", "#CD8F99"];
export const judgeColor = "#8AA0B4";
export const tint = (model: string, modelIDs: string[]) => palette[Math.max(modelIDs.indexOf(model), 0) % palette.length];

const compactOne = new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 });
const compactDefault = new Intl.NumberFormat("en-US", { notation: "compact" });
const grouped = new Intl.NumberFormat("en-US");
export const compact = (value: number) => compactOne.format(value);
export const compactShort = (value: number) => compactDefault.format(value);
export const group = (value: number) => grouped.format(value);
export const percent = (fraction: number) => (fraction * 100).toFixed(1);
export const rate = (value: number) => value === 0 ? "0" : value < 0.1 ? value.toFixed(4) : value.toFixed(2);
export const shortTime = (ms: number) => new Date(ms).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" });
export const standardTime = (ms: number) => new Date(ms).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit", second: "2-digit" });
export const seconds = (ms: number) => (ms / 1000).toFixed(ms >= 100_000 ? 0 : 1);
export const milliseconds = (value: number) => value >= 100 ? String(Math.round(value)) : value.toFixed(1);
export function durationText(secondsValue: number): string {
  const t = Math.round(secondsValue);
  if (t < 60) return `${t} s`;
  if (t < 3600) return `${Math.floor(t / 60)} min`;
  return `${Math.floor(t / 3600)} h ${Math.floor((t % 3600) / 60)} min`;
}

// ---------- log records (RoutingLogReader) ----------

const normalize = (key: string) => key.toLowerCase().replace(/[^a-z0-9]/g, "");
function flatten(value: Raw, prefix = "", out: Raw = {}): Raw {
  for (const [key, child] of Object.entries(value)) {
    const path = prefix ? `${prefix}.${key}` : key;
    if (child !== null && typeof child === "object" && !Array.isArray(child)) flatten(child as Raw, path, out);
    else out[path] = child;
  }
  return out;
}
class Lookup {
  private aliases = new Map<string, unknown>();
  constructor(private exact: Raw) {
    for (const [path, value] of Object.entries(exact)) {
      for (const name of [normalize(path), normalize(path.slice(path.lastIndexOf(".") + 1))]) if (!this.aliases.has(name)) this.aliases.set(name, value);
    }
  }
  value(key: string): unknown { return key in this.exact ? this.exact[key] : this.aliases.get(normalize(key)); }
}
function asString(value: unknown): string {
  if (typeof value === "number") return Number.isInteger(value) && Math.abs(value) < 1e15 ? String(value) : value.toPrecision(4);
  if (Array.isArray(value)) return value.map(asString).join(", ");
  return String(value);
}
function stringField(fields: Lookup, keys: string[]): string | null {
  for (const key of keys) {
    const value = fields.value(key);
    if (value == null) continue;
    const text = asString(value).trim();
    if (text && text !== "null") return text;
  }
  return null;
}
function boolField(fields: Lookup, keys: string[]): boolean {
  for (const key of keys) {
    const value = fields.value(key);
    if (value == null) continue;
    if (typeof value === "boolean" || typeof value === "number") return !!value;
    const text = String(value).trim().toLowerCase();
    if (["true", "yes", "1"].includes(text)) return true;
    if (["false", "no", "0"].includes(text)) return false;
  }
  return false;
}
function intField(fields: Lookup, keys: string[]): number {
  for (const key of keys) {
    const value = fields.value(key);
    if (value === undefined) continue;
    if (typeof value === "number" && Number.isFinite(value)) return Math.trunc(value);
    if (typeof value === "string" && /^-?\d+$/.test(value.trim())) return Number(value);
    return 0;
  }
  return 0;
}
function contextTokens(fields: Lookup): number | null {
  for (const key of ["prompt_tokens", "input_tokens"]) {
    const value = fields.value(key);
    if (typeof value === "number" && Number.isInteger(value) && value >= 0) return value;
    if (typeof value === "string" && /^\d+$/.test(value.trim())) return Number(value);
  }
  return null;
}
function timestampField(fields: Lookup): number | null {
  for (const key of ["ts", "timestamp", "time", "at", "started_at", "recorded_at", "received_at"]) {
    const value = fields.value(key);
    if (typeof value === "string") { const parsed = Date.parse(value); if (Number.isFinite(parsed)) return parsed; }
    if (typeof value === "number" && Number.isFinite(value)) return value > 1e12 ? value : value * 1000;
  }
  return null;
}

export function parseRecord(raw: Raw, id: number): LogRecord {
  const fields = new Lookup(flatten(raw));
  const prompt = intField(fields, ["prompt_tokens", "input_tokens"]);
  const completion = intField(fields, ["completion_tokens", "output_tokens"]);
  const reported = intField(fields, ["total_tokens"]);
  const model = stringField(fields, ["model", "selected_model", "model_id"]);
  const tier = stringField(fields, ["tier", "selected_target", "target"]);
  return {
    id, raw, ts: timestampField(fields), model, tier,
    origin: stringField(fields, ["origin", "client"]),
    sessionID: stringField(fields, ["session_id", "session", "conversation_id"]),
    agentID: stringField(fields, ["agent_id", "subagent_id", "thread_id"]),
    isDelegated: boolField(fields, ["delegated", "is_delegated_work", "is_subagent"]),
    agentKind: stringField(fields, ["agent_kind", "subagent_kind"]),
    agentRole: stringField(fields, ["agent_role"]),
    subagentIdentityUnsupported: boolField(fields, ["subagent_identity_unsupported"]),
    route: stringField(fields, ["route_id", "route", "router"]),
    tokens: {
      prompt, completion,
      cached: intField(fields, ["cached_tokens", "cache_read_tokens"]),
      cacheCreation: intField(fields, ["cache_creation_tokens"]),
      reasoning: intField(fields, ["reasoning_tokens"]),
      total: reported > 0 ? reported : prompt + completion,
    },
    contextInputTokens: contextTokens(fields),
    modelIdentity: model ?? "unknown",
    isClassifier: (tier ?? "").toLowerCase() === "classifier",
  };
}
/** Raw rows arrive newest first; outcome rows are already dropped by the backend. */
export const parseRecords = (rows: Raw[]) => rows.filter((row) => !(row.outcome && typeof row.outcome === "object")).map(parseRecord);

export function droppingHousekeepingThreads(records: LogRecord[], rolloutSessionIDs: Set<string>): LogRecord[] {
  const served = new Map<string, number>();
  for (const record of records) {
    if (record.origin === "codex-cli" && record.sessionID && !record.isClassifier) served.set(record.sessionID, (served.get(record.sessionID) ?? 0) + 1);
  }
  const housekeeping = new Set([...served].filter(([id, count]) => count === 1 && !rolloutSessionIDs.has(id)).map(([id]) => id));
  return records.filter((record) => record.origin !== "codex-cli" || !record.sessionID || !housekeeping.has(record.sessionID));
}

// ---------- sessions (RoutingSession) ----------

export interface Session {
  id: string; startedAt: number | null; lastActivity: number | null; tokens: number; turns: number; classifierCalls: number; models: string[];
  origin: string | null; shortID: string; title: string; shortTitle: string; detail: string;
}
export function sessions(records: LogRecord[]): Session[] {
  const map = new Map<string, Session>();
  for (const record of records) {
    if (!record.sessionID) continue;
    let session = map.get(record.sessionID);
    if (!session) {
      const shortID = record.sessionID.slice(-6);
      session = { id: record.sessionID, startedAt: null, lastActivity: null, tokens: 0, turns: 0, classifierCalls: 0, models: [], origin: null, shortID, title: `Session ${shortID}`, shortTitle: "", detail: "" };
      map.set(record.sessionID, session);
    }
    if (record.ts != null) {
      session.startedAt = session.startedAt == null ? record.ts : Math.min(session.startedAt, record.ts);
      session.lastActivity = session.lastActivity == null ? record.ts : Math.max(session.lastActivity, record.ts);
    }
    session.tokens += record.tokens.total;
    if (record.isClassifier) session.classifierCalls++;
    else { session.turns++; if (!session.models.includes(record.modelIdentity)) session.models.push(record.modelIdentity); }
    session.origin ??= record.origin;
  }
  return [...map.values()].map((session) => {
    session.shortTitle = session.title.length <= 34 ? session.title : `${session.title.slice(0, 33).trim()}…`;
    session.detail = [session.startedAt == null ? null : shortTime(session.startedAt), `${session.turns} ${session.turns === 1 ? "turn" : "turns"}`, session.models.join(", ") || "no model recorded"].filter(Boolean).join(" · ");
    return session;
  }).sort((a, b) => a.lastActivity == null && b.lastActivity == null ? a.id.localeCompare(b.id) : a.lastActivity == null ? 1 : b.lastActivity == null ? -1 : b.lastActivity - a.lastActivity);
}
export const sessionSpan = (session: Session | null) => session && session.startedAt != null && session.lastActivity != null && session.lastActivity >= session.startedAt ? { start: session.startedAt, end: session.lastActivity } : null;
export function activeSessionIDs(records: LogRecord[], now: number): Set<string> {
  return new Set(records.filter((record) => record.sessionID && (record.ts == null || (record.ts >= now - 15 * 60_000 && record.ts <= now + 60_000))).map((record) => record.sessionID!));
}

// ---------- routing profile view (assignments, roles) ----------

export interface FlowRole { name: string; effort: string | null; rank: number }
const efforts = ["low", "medium", "high", "xhigh", "max", "ultra"];
export interface Profile { assignments: Map<string, string>; roles: Map<string, FlowRole>; targetNames: Map<string, string>; configured: string[]; usesClassifier: boolean; classifierModelID: string | null }
export function profile(settings: RouteSettings): Profile {
  const roles = settings.roles ?? builtInRoles;
  const targets = servingTargets(settings);
  const assignments = new Map<string, string>();
  const flowRoles = new Map<string, FlowRole>();
  const targetNames = new Map<string, string>();
  const configured: string[] = [];
  for (const target of targets) {
    const role = roles.find((item) => item.id === target.roleId);
    const display = role?.name.trim() || (target.key.charAt(0).toUpperCase() + target.key.slice(1));
    targetNames.set(target.key, display);
    const model = target.model.trim();
    if (!model) continue;
    if (!configured.includes(model)) configured.push(model);
    assignments.set(model, display);
    const candidate = { name: display, effort: role?.effort ?? null, rank: role?.effort ? efforts.indexOf(role.effort) : -1 };
    const existing = flowRoles.get(model);
    if (!existing || existing.rank < candidate.rank) flowRoles.set(model, candidate);
  }
  const usesClassifier = ["capability", "llm_classifier", "escalation", "composite", "advisor"].includes(settings.algorithm);
  const shared = settings.judgeTarget ? targets.find((target) => target.key === settings.judgeTarget)?.model : null;
  const classifierModelID = settings.jevClassifier?.modelID || settings.judgeModel?.trim() || shared || null;
  return { assignments, roles: flowRoles, targetNames, configured, usesClassifier, classifierModelID };
}
export function roleFor(record: LogRecord, profileValue: Profile): string | null {
  if (record.isClassifier) return "classifier";
  if (record.tier) return profileValue.targetNames.get(record.tier) ?? record.tier;
  return profileValue.assignments.get(record.modelIdentity) ?? null;
}
export function modelIDs(profileValue: Profile, records: LogRecord[], now: number): string[] {
  const observed = new Set(records.filter((record) => !record.isClassifier && (record.ts == null || record.ts >= now - 6 * 3600_000)).map((record) => record.modelIdentity));
  return [...profileValue.configured, ...[...observed].filter((id) => !profileValue.configured.includes(id)).sort()];
}

// ---------- metrics (RoutingMetrics.compute) ----------

export interface Share { id: string; target: string | null; count: number; share: number; requestsPerSecond: number; tokens: number; cachedTokens: number; delegatedCount: number; delegatedTokens: number }
export interface Metrics {
  count: number; tokens: number; cachedTokens: number; requestsPerSecond: number; shares: Share[];
  classifierCount: number; classifierTokens: number; classifierShares: Share[];
  latest: { modelID: string; isClassifier: boolean; at: number | null } | null;
  delegatedCount: number; delegatedTokens: number; delegatedShares: Share[]; uniqueSubagentsCount: number; subagentRoles: Map<string, number>; subagentIdentityUnsupported: boolean;
  windowStart: number; windowEnd: number; windowDuration: number; secondsPerRequest: number | null;
}
interface Group { count: number; tokens: number; cachedTokens: number; models: Map<string, { count: number; tokens: number; cachedTokens: number; delegatedCount: number; delegatedTokens: number; target: string | null }> }
const emptyGroup = (): Group => ({ count: 0, tokens: 0, cachedTokens: 0, models: new Map() });
function add(group: Group, record: LogRecord, delegated = false) {
  group.count++; group.tokens += record.tokens.total; group.cachedTokens += record.tokens.cached;
  let model = group.models.get(record.modelIdentity);
  if (!model) { model = { count: 0, tokens: 0, cachedTokens: 0, delegatedCount: 0, delegatedTokens: 0, target: null }; group.models.set(record.modelIdentity, model); }
  model.count++; model.tokens += record.tokens.total; model.cachedTokens += record.tokens.cached;
  if (delegated) { model.delegatedCount++; model.delegatedTokens += record.tokens.total; }
  if (record.tier) model.target = record.tier;
}
function shares(group: Group, durationSeconds: number, assignments?: Map<string, string>): Share[] {
  const models = new Map(group.models);
  for (const [model] of assignments ?? []) if (!models.has(model)) models.set(model, { count: 0, tokens: 0, cachedTokens: 0, delegatedCount: 0, delegatedTokens: 0, target: null });
  return [...models.entries()].map(([id, value]) => ({
    id, target: value.target ?? assignments?.get(id) ?? null, count: value.count, share: group.count === 0 ? 0 : value.count / group.count,
    requestsPerSecond: value.count / durationSeconds, tokens: value.tokens, cachedTokens: value.cachedTokens, delegatedCount: value.delegatedCount, delegatedTokens: value.delegatedTokens,
  })).sort((a, b) => b.count - a.count || a.id.localeCompare(b.id));
}
export function computeMetrics(records: LogRecord[], now: number, span: { start: number; end: number } | null, assignments: Map<string, string>): Metrics {
  const range = 15 * 60_000;
  const start = span?.start ?? now - range;
  const end = span?.end ?? now;
  const durationSeconds = span ? Math.max((span.end - span.start) / 1000, 1) : range / 1000;
  const futureLimit = end + 60_000;
  const served = emptyGroup(), classifier = emptyGroup(), delegated = emptyGroup();
  const subagents = new Set<string>();
  const subagentRoles = new Map<string, number>();
  let newest: LogRecord | null = null;
  let unsupported = false;
  for (const record of records) {
    if (record.ts != null && (record.ts < start || record.ts > futureLimit)) continue;
    if (!newest || (record.ts != null && (newest.ts == null || record.ts > newest.ts))) newest = newest && record.ts == null ? newest : record;
    if (record.subagentIdentityUnsupported) unsupported = true;
    if (record.isClassifier) { add(classifier, record); continue; }
    add(served, record, record.isDelegated);
    if (record.isDelegated) {
      add(delegated, record);
      if (record.agentID) subagents.add(record.agentID);
      const role = record.agentRole ?? record.agentKind ?? "subagent";
      subagentRoles.set(role, (subagentRoles.get(role) ?? 0) + 1);
    }
  }
  const windowDuration = Math.max((end - start) / 1000, 1);
  return {
    count: served.count, tokens: served.tokens, cachedTokens: served.cachedTokens, requestsPerSecond: served.count / durationSeconds,
    shares: shares(served, durationSeconds, assignments),
    classifierCount: classifier.count, classifierTokens: classifier.tokens, classifierShares: shares(classifier, durationSeconds),
    latest: newest ? { modelID: newest.modelIdentity, isClassifier: newest.isClassifier, at: newest.ts } : null,
    delegatedCount: delegated.count, delegatedTokens: delegated.tokens, delegatedShares: shares(delegated, durationSeconds),
    uniqueSubagentsCount: subagents.size, subagentRoles, subagentIdentityUnsupported: unsupported,
    windowStart: start, windowEnd: end, windowDuration, secondsPerRequest: served.count > 1 ? windowDuration / served.count : null,
  };
}
/** FlowRole.ordered: by effort rank, then traffic, then id. */
export function lanes(metrics: Metrics, roles: Map<string, FlowRole>): Share[] {
  if (roles.size === 0) return metrics.shares;
  const rank = (id: string) => roles.get(id)?.rank ?? -1;
  return [...metrics.shares].sort((a, b) => rank(b.id) - rank(a.id) || b.count - a.count || a.id.localeCompare(b.id));
}

// ---------- ticks & context ----------

export interface Tick { position: number; weight: number }
export function ticks(records: LogRecord[], sessionID: string | null, start: number, end: number): Map<string, Tick[]> {
  const span = Math.max(end - start, 1);
  let heaviest = 1;
  const placed = new Map<string, { position: number; total: number }[]>();
  for (const record of records) {
    if (record.isClassifier || record.ts == null) continue;
    if (sessionID != null && record.sessionID !== sessionID) continue;
    const position = (record.ts - start) / span;
    if (position < -0.001 || position > 1.001) continue;
    heaviest = Math.max(heaviest, record.tokens.total);
    const list = placed.get(record.modelIdentity) ?? [];
    list.push({ position: Math.min(Math.max(position, 0), 1), total: record.tokens.total });
    placed.set(record.modelIdentity, list);
  }
  return new Map([...placed].map(([model, list]) => [model, list.sort((a, b) => a.position - b.position).map((item) => ({ position: item.position, weight: Math.sqrt(item.total / heaviest) }))]));
}
export interface ContextUsage { inputTokens: number | null; contextWindow: number | null; fraction: number | null }
export function contextUsage(records: LogRecord[], sessionID: string, settings: RouteSettings, table: PriceTable | null = null): Map<string, ContextUsage> {
  const newest = new Map<string, LogRecord>();
  for (const record of records) {
    if (record.isClassifier || record.sessionID !== sessionID) continue;
    const existing = newest.get(record.modelIdentity);
    if (!existing || (record.ts != null && existing.ts != null && record.ts > existing.ts)) newest.set(record.modelIdentity, record);
  }
  return new Map([...newest].map(([model, record]) => {
    const input = record.contextInputTokens;
    const window = contextWindowFor(model, settings, table);
    return [model, { inputTokens: input, contextWindow: window, fraction: input != null && input >= 0 && window ? input / window : null }];
  }));
}

const validWindow = (value: unknown): number | null => typeof value === "number" && Number.isSafeInteger(value) && value > 0 ? value : null;
/** Account metadata wins over public defaults; explicit route limits still cap the meter. */
export function contextWindowFor(model: string, settings: RouteSettings, table: PriceTable | null): number | null {
  let window = validWindow(settings.discoveredModels?.find((entry) => entry.id === model)?.contextWindow);
  if (window == null && table) {
    for (const candidate of modelCandidates(model)) {
      const entry = table[candidate];
      window = validWindow(entry?.max_input_tokens) ?? validWindow(entry?.max_tokens);
      if (window != null) break;
    }
  }
  const explicit = validWindow(settings.contextWindow);
  if (explicit != null) window = window == null ? explicit : Math.min(window, explicit);
  if (settings.allowsLongContext === false) window = Math.min(window ?? 272000, 272000);
  return window;
}

// ---------- server stats (SwitchyardStatsClient) ----------

export interface ModelStats { id: string; requests: number; errors: number; tokens: number; latency: { p50: number; p99: number } | null }
export interface ServerStats {
  totalRequests: number; totalErrors: number; tokens: { prompt: number; completion: number; cached: number; reasoning: number; total: number };
  models: ModelStats[]; overhead: { p50: number; p99: number }; fallbacks: [string, number][]; classifierRequests: number; classifierErrors: number;
}
const num = (value: unknown) => typeof value === "number" && Number.isFinite(value) ? value : typeof value === "string" && value.trim() !== "" && Number.isFinite(Number(value)) ? Number(value) : 0;
const obj = (value: unknown): Raw => value && typeof value === "object" && !Array.isArray(value) ? value as Raw : {};
const has = (value: Raw, key: string) => key in value && value[key] != null;
export function parseStats(raw: unknown): ServerStats {
  const root = obj(raw);
  const tokens = obj(root.total_tokens);
  const models = Object.entries(obj(root.models)).map(([id, entry]) => {
    const value = obj(entry);
    const latency = obj(value.total_latency);
    const requests = typeof entry === "number" ? entry : num(value.calls ?? value.requests ?? value.total_requests);
    return {
      id, requests, errors: num(value.errors ?? value.total_errors), tokens: num(obj(value.tokens).total ?? value.total_tokens),
      latency: num(latency.count) > 0 && has(latency, "p50_ms") && has(latency, "p99_ms") ? { p50: num(latency.p50_ms), p99: num(latency.p99_ms) } : null,
    };
  }).sort((a, b) => b.requests - a.requests);
  const overhead = obj(root.routing_overhead);
  const classifier = obj(root.classifier);
  return {
    totalRequests: num(root.total_requests), totalErrors: num(root.total_errors),
    tokens: { prompt: num(tokens.prompt), completion: num(tokens.completion), cached: num(tokens.cached), reasoning: num(tokens.reasoning), total: num(tokens.total) },
    models, overhead: { p50: num(overhead.p50_ms), p99: num(overhead.p99_ms) },
    fallbacks: Object.entries(obj(root.routing_fallbacks)).map(([key, value]) => [key, num(value)] as [string, number]).filter(([, count]) => count > 0).sort((a, b) => a[0].localeCompare(b[0])),
    classifierRequests: num(classifier.total_requests), classifierErrors: num(classifier.total_errors),
  };
}

// ---------- cost at API list prices (per-token rates) ----------

export type PriceTable = Record<string, Record<string, number>>;
const isPriced = (costs: Record<string, number> | undefined) => !!costs && costs.input_cost_per_token != null && costs.output_cost_per_token != null;
/** The id itself, then without its provider, then under the provider LiteLLM infers for a bare name. */
function modelCandidates(model: string): string[] {
  const id = model.toLowerCase();
  const slash = id.indexOf("/");
  return [id, ...(slash >= 0 ? [id.slice(slash + 1)] : []), ...["openai", "anthropic", "gemini"].map((provider) => `${provider}/${id}`)];
}
export function priceFor(model: string, table: PriceTable): Record<string, number> | null {
  for (const candidate of modelCandidates(model)) if (isPriced(table[candidate])) return table[candidate];
  return null;
}
function threshold(key: string): { label: string; tokens: number } | null {
  const prefix = "input_cost_per_token_above_", suffix = "_tokens";
  if (!key.startsWith(prefix) || !key.endsWith(suffix)) return null;
  const label = key.slice(prefix.length, -suffix.length);
  const thousands = label.endsWith("k");
  const value = Number(thousands ? label.slice(0, -1) : label);
  return label && Number.isFinite(value) ? { label, tokens: thousands ? value * 1000 : value } : null;
}
function rates(costs: Record<string, number>, promptTokens: number) {
  const result = { input: costs.input_cost_per_token ?? 0, output: costs.output_cost_per_token ?? 0, cacheRead: costs.cache_read_input_token_cost ?? 0, cacheCreation: costs.cache_creation_input_token_cost ?? 0, reasoning: 0 };
  const tier = Object.keys(costs).map(threshold).filter((item) => item != null).sort((a, b) => b.tokens - a.tokens).find((item) => promptTokens > item.tokens);
  if (tier) {
    const suffix = `_above_${tier.label}_tokens`;
    result.input = costs[`input_cost_per_token${suffix}`] ?? result.input;
    result.output = costs[`output_cost_per_token${suffix}`] ?? result.output;
    result.cacheCreation = costs[`cache_creation_input_token_cost${suffix}`] ?? result.cacheCreation;
    result.cacheRead = costs[`cache_read_input_token_cost${suffix}`] ?? result.cacheRead;
  }
  result.reasoning = costs.output_cost_per_reasoning_token ?? result.output;
  return result;
}
/** LiteLLM's generic_cost_per_token for a text call: the prompt count already includes cache hits and writes. */
export function callCost(tokens: Tokens, costs: Record<string, number>): number {
  const prompt = Math.max(tokens.prompt, 0);
  const rate = rates(costs, prompt);
  const cached = Math.min(Math.max(tokens.cached, 0), prompt);
  const written = Math.min(Math.max(tokens.cacheCreation, 0), prompt - cached);
  const completion = Math.max(tokens.completion, 0);
  const reasoning = Math.min(Math.max(tokens.reasoning, 0), completion);
  return (prompt - cached - written) * rate.input + cached * rate.cacheRead + written * rate.cacheCreation + (completion - reasoning) * rate.output + reasoning * rate.reasoning;
}
export interface CostEstimate { dollars: number; uncachedDollars: number; pricedCalls: number; unpricedCalls: number; unpricedTokens: number; unpricedModels: string[] }
export function estimateCost(records: LogRecord[], table: PriceTable, aliases: Record<string, string> = {}): CostEstimate {
  const estimate: CostEstimate = { dollars: 0, uncachedDollars: 0, pricedCalls: 0, unpricedCalls: 0, unpricedTokens: 0, unpricedModels: [] };
  const unpriced = new Map<string, number>();
  for (const record of records) {
    const costs = priceFor(aliases[record.modelIdentity] ?? record.modelIdentity, table);
    if (!costs) {
      estimate.unpricedCalls++; estimate.unpricedTokens += record.tokens.total;
      unpriced.set(record.modelIdentity, (unpriced.get(record.modelIdentity) ?? 0) + record.tokens.total);
      continue;
    }
    estimate.pricedCalls++;
    estimate.dollars += callCost(record.tokens, costs);
    estimate.uncachedDollars += callCost({ ...record.tokens, cached: 0, cacheCreation: 0 }, costs);
  }
  estimate.unpricedModels = [...unpriced].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).map(([model]) => model);
  return estimate;
}
export function dollars(value: number): string {
  if (value > 0 && value < 0.01) return "<$0.01";
  return value.toLocaleString("en-US", { style: "currency", currency: "USD", minimumFractionDigits: 2, maximumFractionDigits: 2 });
}
