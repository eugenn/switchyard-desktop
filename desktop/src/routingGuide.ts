import type { Algorithm } from "./api";

/**
 * Plain-language guide to each strategy, used by the Routing page. It explains
 * what decides, what extra model calls cost, and what every model slot does in
 * that strategy. Wording follows the server's routing overview, model
 * selection and strategy pages in the vendored snapshot.
 */
export type StrategyFamily = "recommended" | "signals" | "judge" | "other";
export interface SlotGuide { title: string; job: string }
export interface StrategyGuide {
  family: StrategyFamily;
  /** One outcome-first line for the strategy list. */
  tagline: string;
  /** Model slots in words, e.g. "2 models + judge". */
  needs: string;
  /** What the decision is based on. */
  decides: string;
  /** Extra model calls on top of serving the request. */
  cost: string;
  /** Jobs for the serving slots in order (pair: efficient, capable; single: the only one). */
  slots: SlotGuide[];
  judge?: SlotGuide;
}

export const families: { id: StrategyFamily; title: string }[] = [
  { id: "recommended", title: "Recommended" },
  { id: "signals", title: "Agent progress decides" },
  { id: "judge", title: "A judge model decides" },
  { id: "other", title: "One model, tests and experiments" },
];

const pair = (efficient: string, capable: string): SlotGuide[] => [
  { title: "Efficient", job: efficient },
  { title: "Capable", job: capable },
];
const judgeCost = "One judge call per request, user turn or session; adds the judge's wait time";
const optionalJudge = { title: "Judge", job: "Optional. Asked only when tool results are unclear." };

export const guides: Record<Algorithm, StrategyGuide> = {
  auto: {
    family: "recommended", tagline: "Efficient model by default, Capable when the work gets hard.", needs: "2 models",
    decides: "Tool results in each request", cost: "No extra model calls",
    slots: pair("Serves most turns: routine edits and clear next steps.", "Takes the turns where tool results show the work is getting hard."),
  },
  stage_router: {
    family: "signals", tagline: "Like Auto, with an optional judge for unclear turns.", needs: "2 models, judge optional",
    decides: "Tool results from recent turns", cost: "No extra calls unless you add a judge",
    slots: pair("Serves most turns.", "Takes over when tool results call for more capacity."),
    judge: optionalJudge,
  },
  plan_execute: {
    family: "signals", tagline: "Capable plans the session, then Efficient carries it out.", needs: "2 models, judge optional",
    decides: "Planning first, then tool results", cost: "No extra calls unless you add a judge",
    slots: pair("Carries out the work after the plan, and holds for the rest of the session.", "Plans the work at the start of a session."),
    judge: optionalJudge,
  },
  capability: {
    family: "judge", tagline: "A judge reads each task and picks the model up front.", needs: "2 models + judge",
    decides: "A judge reads the task before it is served", cost: judgeCost,
    slots: pair("Serves tasks the judge rates as routine.", "Serves tasks the judge rates as demanding."),
    judge: { title: "Judge", job: "Reads each task and picks the model before it is served." },
  },
  composite: {
    family: "judge", tagline: "A judge picks the model per user turn; tool results adjust it.", needs: "2 models + judge",
    decides: "A judge at each user turn, tool results in between", cost: "One judge call per user turn or session",
    slots: pair("Starts routine user turns.", "Starts demanding user turns; tool results can still move work up."),
    judge: { title: "Judge", job: "Picks the model that starts each user turn." },
  },
  escalation: {
    family: "judge", tagline: "Efficient first; Capable after the same failure repeats.", needs: "2 models + judge",
    decides: "A judge checks each finished Efficient turn", cost: "One judge call per turn; each Efficient reply waits for the check",
    slots: pair("Serves every turn until the judge sees the same failure twice.", "Takes over for the rest of the session once the judge sees the same failure on consecutive turns."),
    judge: { title: "Judge", job: "Checks each finished Efficient turn for failure." },
  },
  llm_classifier: {
    family: "judge", tagline: "Your own 2–6 targets, chosen by their role descriptions.", needs: "2–6 models + judge",
    decides: "Your judge matches each request to a target's role", cost: judgeCost,
    slots: [],
    judge: { title: "Judge", job: "Reads each request and picks the target whose role description fits best." },
  },
  advisor: {
    family: "judge", tagline: "One model works; an advisor reviews its plans and results.", needs: "1 model + advisor",
    decides: "An advisor reviews finished work", cost: "One review per gated turn",
    slots: [{ title: "Executor", job: "Serves every turn and acts on the advisor's feedback." }],
    judge: { title: "Advisor", job: "Reviews plans and finished work, then approves or asks for a redo." },
  },
  passthrough: {
    family: "other", tagline: "Every request goes to one model.", needs: "1 model",
    decides: "Nothing: one model answers", cost: "No extra model calls",
    slots: [{ title: "Model", job: "Answers every request." }],
  },
  random: {
    family: "other", tagline: "Split requests across 2–6 models.", needs: "2–6 models",
    decides: "A random split", cost: "No extra model calls",
    slots: [],
  },
  vgr: {
    family: "other", tagline: "Shadow test: Capable answers while Efficient drafts are verified.", needs: "2 models, judge optional",
    decides: "Whether the Efficient draft verifies (shadow mode)", cost: "A verifier call for each answer",
    slots: pair("Drafts are checked in the background; in shadow mode none are served.", "Answers every request in shadow mode."),
    judge: { title: "Judge", job: "Optional. Helps verify the Efficient draft." },
  },
  prefill_router: {
    family: "other", tagline: "Needs a server build with prefill enabled, which is not bundled.", needs: "2–6 models + checkpoint",
    decides: "A classifier checkpoint you trained", cost: "Runs on the server, no model calls",
    slots: [],
  },
  noop: {
    family: "other", tagline: "Answers OK without calling a model. For smoke tests.", needs: "No models",
    decides: "Nothing: answers OK without a model", cost: "No model calls",
    slots: [],
  },
};

/** Job for a target of a variable-shape strategy (custom classifier, random, prefill). */
export function variableJob(algorithm: Algorithm): string {
  if (algorithm === "llm_classifier") return "Chosen when the judge matches the request to this role.";
  if (algorithm === "random") return "Receives an equal share of requests.";
  return "Chosen when the checkpoint picks this target.";
}
