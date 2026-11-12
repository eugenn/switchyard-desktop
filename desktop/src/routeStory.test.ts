import { expect, it } from "vitest";
import { routeStory } from "./routeStory";

const base = { efficientModel: "small", capableModel: "large" };

it("holds the first choice for a whole session when the judge runs once per session", () => {
  const story = routeStory({ ...base, algorithm: "capability", classifyTrigger: "new_session" });
  expect(story.map((beat) => beat.serves[0])).toEqual(["efficient", "efficient", "efficient", "efficient"]);
  expect(story.map((beat) => beat.judge)).toEqual([true, false, false, false]);
});

it("calls the judge on every request only when asked to", () => {
  const story = routeStory({ ...base, algorithm: "capability", classifyTrigger: "every_request" });
  expect(story.map((beat) => beat.judge)).toEqual([true, true, true, true]);
  expect(story[2].serves).toEqual(["capable"]);
});

it("serves Capable while Efficient drafts in the shadow for verification-gated routing", () => {
  const story = routeStory({ ...base, algorithm: "vgr" });
  expect(story.every((beat) => beat.serves[0] === "capable" && beat.shadow?.[0] === "efficient")).toBe(true);
});

it("calls no model for no-op", () => {
  expect(routeStory({ ...base, algorithm: "noop" }).every((beat) => beat.serves.length === 0)).toBe(true);
});
