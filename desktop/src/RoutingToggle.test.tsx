import { describe, expect, it } from "vitest";
import { frame, pointOnBranch } from "./RoutingToggle";

describe("switch glyph phases", () => {
  it("draws the branches out top first over a faint track", () => {
    expect(frame("starting", 0).reach(0)).toBe(0);
    expect(frame("starting", 0.05).reach(2)).toBe(0);
    expect(frame("starting", 0.5).reach(0)).toBe(1);
    expect(frame("starting", 0.2).trackOpacity).toBeGreaterThan(0);
    expect(frame("starting", 1.39).branchOpacity).toBeLessThan(0.1);
    expect(frame("idle", 0).trackOpacity).toBe(0);
  });

  it("sends one request down a branch at a time while routing", () => {
    const first = frame("running", 0.75).car!;
    expect(first.branch).toBe(0);
    expect(first.at).toBeCloseTo(0.5, 5);
    expect(frame("running", 1.5 + 0.75).car!.branch).toBe(2);
    expect(frame("running", 0).car!.opacity).toBe(0);
    expect(frame("idle", 3).car).toBeNull();
  });

  it("pulls the middle branch back first on stop", () => {
    expect(frame("stopping", 0.3).reach(1)).toBeLessThan(frame("stopping", 0.3).reach(0));
    expect(frame("stopping", 0.9).reach(0)).toBe(0);
  });

  it("runs a request from the source to each branch end", () => {
    expect(pointOnBranch(0, 0)).toEqual([3.5, 12]);
    expect(pointOnBranch(0, 1)).toEqual([21, 5.5]);
    expect(pointOnBranch(2, 1)).toEqual([21, 18.5]);
    expect(pointOnBranch(1, 0.45)[1]).toBe(12);
  });
});
