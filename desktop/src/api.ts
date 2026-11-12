import { invoke, isTauri } from "@tauri-apps/api/core";

import catalog from "../shared/algorithms.json";
import shippedRoles from "../shared/roles.json";

export type Algorithm = "auto" | "stage_router" | "capability" | "llm_classifier" | "escalation" | "composite" | "advisor" | "random" | "passthrough" | "noop" | "prefill_router" | "plan_execute" | "vgr";
export const algorithms = catalog as { value: Algorithm; label: string; description: string; shape: "pair" | "variable" | "single" | "none"; judge: boolean }[];
export interface RoutingRole {
  id: string; kind: "target" | "classifier"; name: string; text: string;
  systemPrompt?: string | null; effort?: string | null; tags: string[]; groupIDs: string[]; isBuiltIn: boolean;
}
export interface RoleGroup { id: string; name: string; projectPath: string; routingProfile?: RouteSettings | null }
/** Connections a model can be served by: the ChatGPT plan or a provider API key. */
export type ConnectionId = "chatgpt" | "openai" | "anthropic" | "openrouter";
export type DecisionEngine = "jev" | "mercury";
export interface ModelTarget {
  key: string; model: string; roleId: string | null; nativeOptions: string;
  connection?: ConnectionId;
  /** Legacy provider, read for setups saved before connections. */
  provider?: "openai" | "anthropic" | "openrouter";
}
export interface RouteSettings {
  algorithm: Algorithm;
  efficientModel: string;
  capableModel: string;
  efficientRoleId?: string | null;
  capableRoleId?: string | null;
  efficientOptions?: string;
  capableOptions?: string;
  targets?: ModelTarget[];
  additionalTargets?: ModelTarget[];
  judgeModel?: string;
  judgeTarget?: string | null;
  judgeOptions?: string;
  classifierRoleId?: string;
  classifyTrigger?: string;
  defaultTarget?: string;
  reviewerSystemPrompt?: string;
  nativeRouteOptions?: string;
  roles?: RoutingRole[];
  roleGroups?: RoleGroup[];
  contextWindow?: number | null;
  allowsLongContext?: boolean;
  vision?: boolean;
  reasoningSummaries?: boolean;
  checkpoint?: string;
  manageCodexProfile?: boolean;
  discoveredModels?: AvailableModel[];
  codexExecutable?: string;
  /** A decision model (Jev or Mercury Decide) in place of an LLM judge. */
  jevClassifier?: { modelID: string; cutoff: number; instructions: string; engine?: DecisionEngine } | null;
  /** Legacy OpenAI access, read for setups saved before connections. */
  openaiAuth?: "subscription" | "api_key";
  /** Connection that serves a separate LLM judge. */
  judgeConnection?: ConnectionId;
}
export const builtInRoles = shippedRoles as RoutingRole[];
export function servingTargets(settings: RouteSettings): ModelTarget[] {
  const shape = algorithms.find((algorithm) => algorithm.value === settings.algorithm)!.shape;
  if (shape === "none") return [];
  if (settings.targets?.length) return settings.targets;
  const targets: ModelTarget[] = [{ key: "efficient", model: settings.efficientModel, roleId: settings.efficientRoleId ?? null, nativeOptions: settings.efficientOptions ?? "" }];
  if (shape !== "single") targets.push({ key: "capable", model: settings.capableModel, roleId: settings.capableRoleId ?? null, nativeOptions: settings.capableOptions ?? "" });
  return targets;
}
export interface AvailableModel { id: string; displayName: string; supportsImages: boolean; contextWindow: number | null; efforts: string[] }
export interface ClaudeSettings { efficientModel: string; capableModel: string }
export interface RuntimeStatus {
  available: boolean;
  platform: string;
  missing: string[];
}
export interface SessionStatus {
  running: boolean;
  endpoint: string;
  message: string;
}
export interface LoginStatus {
  pending: boolean;
  signedIn: boolean;
  code: string | null;
  verificationUrl: string | null;
  message: string;
}
export interface Bootstrap {
  settings: RouteSettings;
  login: LoginStatus;
  runtime: RuntimeStatus;
  session: SessionStatus;
}
export interface ConfigurationPreview {
  switchyard: string;
  litellm: string;
  codex: string;
}
export interface Stats {
  total_requests?: number;
  total_errors?: number;
  total_tokens?: { total?: number; cached?: number };
  models?: Record<string, { calls?: number; errors?: number; tokens?: { total?: number } }>;
  routing_overhead?: { p50_ms?: number; p99_ms?: number };
}

export const native = isTauri();

export const api = {
  claudeSettings: () => invoke<ClaudeSettings>("claude_settings"),
  saveClaudeSettings: (settings: ClaudeSettings) => invoke<void>("save_claude_settings", { settings }),
  claudeLaunchCommand: (settings: ClaudeSettings) => invoke<string>("claude_launch_command", { settings }),
  anthropicKeyStatus: () => invoke<boolean>("anthropic_key_status"),
  saveAnthropicKey: (key: string) => invoke<void>("save_anthropic_key", { key }),
  connections: () => invoke<Connection[]>("connections"),
  saveConnectionKey: (connection: KeyedConnection, key: string) => invoke<void>("save_connection_key", { connection, key }),
  refreshConnection: (connection: KeyedConnection) => invoke<Connection>("refresh_connection", { connection }),
  typesafeKeyStatus: () => invoke<boolean>("typesafe_key_status"),
  saveTypesafeKey: (key: string) => invoke<void>("save_typesafe_key", { key }),
  saveLibrary: (roles: RoutingRole[], groups: RoleGroup[]) => invoke<void>("save_role_library", { roles, groups }),
  discoverModels: (executable: string) => invoke<AvailableModel[]>("discover_models", { executable }),
  importSetup: (text: string) => invoke<RouteSettings>("import_setup", { text }),
  bootstrap: () => invoke<Bootstrap>("bootstrap"),
  preview: (settings: RouteSettings) => invoke<ConfigurationPreview>("preview_configuration", { settings }),
  save: (settings: RouteSettings) => invoke<void>("save_settings", { settings }),
  start: (settings: RouteSettings) => invoke<SessionStatus>("start_routing", { settings }),
  stop: () => invoke<SessionStatus>("stop_routing"),
  status: () => invoke<SessionStatus>("session_status"),
  stats: () => invoke<Stats>("read_stats"),
  history: () => invoke<Record<string, unknown>[]>("routing_history"),
  modelPrices: (refresh = false) => invoke<Record<string, Record<string, number>>>("model_prices", { refresh }),
  rolloutSessionIDs: (sessionIds: string[]) => invoke<string[]>("rollout_session_ids", { sessionIds }),
  beginLogin: () => invoke<LoginStatus>("begin_login"),
  loginStatus: () => invoke<LoginStatus>("login_status"),
  cancelLogin: () => invoke<LoginStatus>("cancel_login"),
};

export const emptySettings: RouteSettings = { algorithm: "auto", efficientModel: "", capableModel: "" };
export const stopped: SessionStatus = { running: false, endpoint: "http://127.0.0.1:4100/v1", message: "Routing is stopped." };

export function validationMessage(settings: RouteSettings): string | null {
  const algorithm = algorithms.find((item) => item.value === settings.algorithm)!;
  const targets = [...servingTargets(settings), ...(settings.additionalTargets ?? [])];
  if (targets.some((target) => !/^[a-zA-Z0-9._:/-]{1,200}$/.test(target.model))) return "Enter a valid model ID for each target.";
  if (settings.algorithm === "llm_classifier" && !settings.nativeRouteOptions?.trim() && servingTargets(settings).some((target) => !(settings.roles ?? builtInRoles).some((role) => role.id === target.roleId && role.kind === "target" && role.text.trim()))) return "Assign a described role to each classifier target.";
  if (settings.jevClassifier && (!Number.isFinite(settings.jevClassifier.cutoff) || settings.jevClassifier.cutoff < 0 || settings.jevClassifier.cutoff > 1)) return "Choose a Jev cutoff between 0 and 1.";
  if (algorithm.judge && !settings.jevClassifier && !settings.judgeTarget && !/^[a-zA-Z0-9._:/-]{1,200}$/.test(settings.judgeModel ?? "")) return "Choose a judge model or an existing judge target.";
  if (settings.algorithm === "prefill_router" && !settings.nativeRouteOptions?.trim() && !settings.checkpoint?.trim()) return "Prefill requires a checkpoint and a feature-enabled server.";
  return null;
}

export type KeyedConnection = Exclude<ConnectionId, "chatgpt"> | "typesafe";
export interface Connection {
  id: ConnectionId | "typesafe";
  connected: boolean;
  keyHint: string;
  models: AvailableModel[];
  refreshedAt: number | null;
  checkedAt: number | null;
  latencyMs: number | null;
  error: string;
}

export const connectionIds: ConnectionId[] = ["chatgpt", "openai", "anthropic", "openrouter"];
export const connectionInfo: Record<ConnectionId | "typesafe", { name: string; short: string; billing: "Plan" | "API" | "Key" }> = {
  chatgpt: { name: "ChatGPT plan", short: "ChatGPT", billing: "Plan" },
  openai: { name: "OpenAI API", short: "OpenAI", billing: "API" },
  anthropic: { name: "Anthropic", short: "Anthropic", billing: "API" },
  openrouter: { name: "OpenRouter", short: "OpenRouter", billing: "API" },
  typesafe: { name: "TypeSafe", short: "TypeSafe", billing: "Key" },
};

/** The connection a model uses: its own, else the legacy provider and OpenAI access. Mirrors RouteSettings::connection_of. */
export function connectionOf(settings: RouteSettings, target: Pick<ModelTarget, "connection" | "provider">): ConnectionId {
  if (target.connection && connectionIds.includes(target.connection)) return target.connection;
  if (target.provider === "anthropic" || target.provider === "openrouter") return target.provider;
  return settings.openaiAuth === "api_key" ? "openai" : "chatgpt";
}

/** Connections the setup needs to start. Mirrors RouteSettings::used_connections. */
export function usedConnections(settings: RouteSettings): Set<ConnectionId | "typesafe"> {
  const used = new Set<ConnectionId | "typesafe">();
  if (settings.algorithm === "noop") return used;
  for (const target of [...servingTargets(settings), ...(settings.additionalTargets ?? [])]) used.add(connectionOf(settings, target));
  if (settings.jevClassifier) used.add(settings.jevClassifier.engine === "mercury" ? "openrouter" : "typesafe");
  else if (!settings.judgeTarget && (settings.judgeModel || algorithms.find((item) => item.value === settings.algorithm)!.judge)) used.add(connectionOf(settings, { connection: settings.judgeConnection }));
  return used;
}
