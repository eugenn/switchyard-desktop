import { servingTargets, type RouteSettings } from "./api";

/**
 * A fixed four-beat coding session, told through the selected strategy's own
 * rule. It illustrates how the strategy decides; it never predicts what a
 * real judge or real tool results would do.
 */
export interface StoryBeat {
  /** What happens in the session. */
  event: string;
  kind: "user" | "tools";
  /** Target keys that serve this beat. Empty when no model is called. */
  serves: string[];
  /** Target keys that run in the background only (shadow drafts). */
  shadow?: string[];
  /** Whether the judge or advisor is called on this beat. */
  judge: boolean;
  /** Why, in the strategy's terms. */
  why: string;
}

export const storyEvents = [
  { event: "“Rename getUser to fetchUser”", kind: "user" as const },
  { event: "Tool results: tests pass", kind: "tools" as const },
  { event: "“Redesign auth across the services”", kind: "user" as const },
  { event: "Tool results: the same test fails again", kind: "tools" as const },
];

type Beat = Omit<StoryBeat, "event" | "kind">;

export function routeStory(settings: RouteSettings, nameOf: (key: string) => string = (key) => key): StoryBeat[] {
  const targets = servingTargets(settings).map((target) => target.key);
  const [first = "efficient", second = "capable"] = targets;
  const last = targets[targets.length - 1] ?? second;
  const trigger = settings.classifyTrigger ?? "every_request";
  const hasJudge = !!settings.judgeModel || !!settings.judgeTarget || !!settings.jevClassifier;
  const beat = (serves: string[], judge: boolean, why: string, shadow?: string[]): Beat => ({ serves, judge, why, shadow });
  const perTurn = trigger !== "new_session";
  const everyRequest = trigger === "every_request";

  const beats: Record<RouteSettings["algorithm"], Beat[]> = {
    auto: [
      beat([first], false, "Auto starts every session on Efficient."),
      beat([first], false, "Tool results look routine, so Efficient keeps the work."),
      beat([first], false, "Auto does not read the request text. The new turn stays on Efficient until tool results say otherwise."),
      beat([second], false, "Tool results show the work getting hard, so Capable takes over."),
    ],
    stage_router: [
      beat([first], false, "Stage router starts on Efficient."),
      beat([first], false, "Clear, routine tool results: Efficient keeps the work."),
      beat([first], false, "The request text alone does not move the work. Tool results decide."),
      beat([second], hasJudge, hasJudge ? "Repeated failure moves work to Capable. Unclear results are sent to your optional judge." : "Repeated failure in tool results moves the work to Capable."),
    ],
    plan_execute: [
      beat([second], false, "Capable plans the session first."),
      beat([first], false, "Efficient carries out the plan."),
      beat([first], false, "The plan holds for the rest of the session, so Efficient keeps executing."),
      beat([first], hasJudge, hasJudge ? "Efficient keeps executing. Unclear tool results go to your optional judge." : "Efficient keeps executing; tool results steer it from here."),
    ],
    capability: [
      beat([first], true, "The judge reads the task and rates it routine: Efficient serves it."),
      beat([first], everyRequest, everyRequest ? "The judge runs on every request, including this tool continuation." : "No new judge call: the choice holds until the next " + (perTurn ? "user turn." : "session.")),
      perTurn ? beat([second], true, "The judge rates the redesign as demanding: Capable serves it.") : beat([first], false, "Once per session: the first choice holds, even for a harder request."),
      perTurn ? beat([second], everyRequest, "Capable keeps the demanding task.") : beat([first], false, "The session's first choice still holds."),
    ],
    composite: [
      beat([first], true, "At each user turn the judge picks the starting model: Efficient."),
      beat([first], false, "Between user turns, tool results steer. Routine results stay on Efficient."),
      perTurn ? beat([second], true, "New user turn: the judge rates it demanding and starts Capable.") : beat([first], false, "Once per session: the first pick holds for this turn."),
      beat([second], false, perTurn ? "Capable keeps the turn while tool results are failing." : "Failing tool results move the work up to Capable."),
    ],
    escalation: [
      beat([first], true, "Efficient answers; the judge checks the finished turn and finds no failure."),
      beat([first], true, "Still no failure: Efficient keeps serving."),
      beat([first], true, "Efficient takes the new request. The judge sees a first failure."),
      beat([second], true, "The same failure twice in a row: Capable takes over for the rest of the session."),
    ],
    llm_classifier: [
      beat([first], true, `The judge matches the request to the role of ${nameOf(first)}.`),
      beat([first], everyRequest, everyRequest ? "The judge runs again on this continuation and keeps the same target." : "No new judge call: the target holds."),
      perTurn ? beat([last], true, `The judge matches the redesign to the role of ${nameOf(last)}.`) : beat([first], false, "Once per session: the first target holds."),
      beat([perTurn ? last : first], everyRequest, "The chosen target keeps the task."),
    ],
    advisor: [
      beat([first], true, "The executor plans; the advisor reviews the plan before work starts."),
      beat([first], false, "The executor works on its own between gated turns."),
      beat([first], true, "The advisor reviews the finished work and approves it."),
      beat([first], true, "The advisor asks for a redo. The executor acts on the feedback."),
    ],
    passthrough: storyEvents.map(() => beat([first], false, "Every request goes to the one model.")),
    random: storyEvents.map((_, index) => beat([targets[(index * 3 + 1) % Math.max(targets.length, 1)] ?? first], false, "A random split picks a target. Nothing about the request is read.")),
    vgr: storyEvents.map((_, index) => beat([second], hasJudge && index % 2 === 1, "Capable answers. Efficient drafts the same answer in the background and the draft is verified, but not served.", [first])),
    prefill_router: storyEvents.map(() => beat([first], false, "Your trained checkpoint picks a target on the server. No model call decides.")),
    noop: storyEvents.map(() => beat([], false, "Answers OK without calling any model.")),
  };
  return storyEvents.map((item, index) => ({ ...item, ...beats[settings.algorithm][index] }));
}
