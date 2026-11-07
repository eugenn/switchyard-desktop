// One compact
// toolbar control that starts routing, shows a start or stop in flight, and
// stops routing again. It wears the toolbar's own button skin; colour only
// marks state, the way the brand dot does.
import { useEffect, useState } from "react";

export type RoutingPhase = "idle" | "starting" | "running" | "stopping";

/** Whether the glyph can play its phases; without motion a start or stop is not held. */
export const canAnimate = () => typeof matchMedia === "function" && !matchMedia("(prefers-reduced-motion: reduce)").matches;
/** One full draw-out of the start glyph, and the branches pulling all the way back in. */
export const minimumHold: Record<"starting" | "stopping", number> = { starting: 1200, stopping: 1000 };

/** The app icon's one-input, three-output switch in a 26 x 24 grid. */
const branchY = [5.5, 12, 18.5];
const STEM = "M3.5 12 L8 12";
const branchPath = (y: number) => y === 12 ? "M8 12 L21 12" : `M8 12 C12 12 12 ${y} 16 ${y} L21 ${y}`;

const START_CYCLE = 1.4, CAR_CYCLE = 1.5;
const startStagger = [0, 0.1, 0.2];
/** On a stop the middle branch goes first, then the bottom, then the top. */
const stopStagger = [0.15, 0, 0.08];
/** The order a running request takes the branches: top, bottom, middle. */
const carOrder = [0, 2, 1];
const clamp = (value: number) => Math.min(Math.max(value, 0), 1);
const fraction = (value: number) => value - Math.floor(value);
const easeOut = (value: number) => 1 - Math.pow(1 - value, 3);
const easeIn = (value: number) => value * value;
const easeInOut = (value: number) => value < 0.5 ? 4 * value ** 3 : 1 - Math.pow(-2 * value + 2, 3) / 2;

/** A point `s` of the way from the source along branch `index` (stem, curve, then straight). */
export function pointOnBranch(index: number, s: number): [number, number] {
  const y = branchY[index];
  if (s <= 0.2) return [3.5 + 4.5 * s / 0.2, 12];
  if (s >= 0.7) return [16 + 5 * (s - 0.7) / 0.3, y];
  const t = (s - 0.2) / 0.5, u = 1 - t;
  const x = u ** 3 * 8 + 3 * u * u * t * 12 + 3 * u * t * t * 12 + t ** 3 * 16;
  return [x, u ** 3 * 12 + 3 * u * u * t * 12 + 3 * u * t * t * y + t ** 3 * y];
}

/** Where each branch and the travelling request are `elapsed` seconds into a phase. */
export function frame(phase: RoutingPhase, elapsed: number) {
  const startT = fraction(elapsed / START_CYCLE) * START_CYCLE;
  return {
    /** How far each branch is drawn out of the stem. */
    reach: (index: number) => phase === "starting" ? easeOut(clamp((startT - startStagger[index]) / 0.5))
      : phase === "stopping" ? 1 - easeIn(clamp((elapsed - stopStagger[index]) / 0.6)) : 1,
    /** Ink of the drawn branches: a start fades out before it draws again; routing quiets the rails under the request. */
    branchOpacity: phase === "running" ? 0.5 : phase === "starting" ? 1 - clamp((startT - 1.15) / 0.25) : 1,
    /** The full switch stays faintly in place while a start or stop draws over it, so no frame is empty. */
    trackOpacity: phase === "starting" || phase === "stopping" ? 0.22 : 0,
    /** The one request on its way down a branch while routing. */
    car: phase === "running" ? (() => {
      const lap = elapsed / CAR_CYCLE;
      const at = easeInOut(fraction(lap));
      return { branch: carOrder[Math.floor(lap) % 3], at, opacity: clamp(Math.min(at, 1 - at) * 8) };
    })() : null,
  };
}

/** Elapsed seconds since the phase began, ticking at ~30 fps while the glyph moves. */
function usePhaseClock(phase: RoutingPhase, animates: boolean): number {
  const [began, setBegan] = useState(() => performance.now());
  const [now, setNow] = useState(began);
  useEffect(() => { const at = performance.now(); setBegan(at); setNow(at); }, [phase]);
  useEffect(() => {
    if (!animates) return;
    let handle = 0, last = 0;
    const tick = (time: number) => {
      if (time - last >= 1000 / 30 && document.visibilityState === "visible") { last = time; setNow(time); }
      handle = requestAnimationFrame(tick);
    };
    handle = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(handle);
  }, [animates, phase]);
  return Math.max(now - began, 0) / 1000;
}

function SwitchGlyph({ phase }: { phase: RoutingPhase }) {
  const animates = phase !== "idle" && canAnimate();
  const elapsed = usePhaseClock(phase, animates);
  const f = frame(animates || phase === "running" ? phase : "idle", elapsed);
  const car = f.car && animates ? f.car : null;
  const line = { fill: "none", stroke: "currentColor", strokeWidth: 2.4, strokeLinecap: "round", strokeLinejoin: "round" } as const;
  return <svg className="switch-glyph" width="19" height="18" viewBox="0 0 26 24" aria-hidden="true">
    <g className="switch-fork">
      <path d={STEM} {...line} />
      {branchY.map((y, index) => {
        const reach = f.reach(index);
        return <g key={y}>
          {f.trackOpacity > 0 && <path d={branchPath(y)} {...line} strokeOpacity={f.trackOpacity} />}
          {reach > 0.001 && <path d={branchPath(y)} pathLength={1} {...line} strokeOpacity={f.branchOpacity}
            strokeDasharray={reach >= 1 ? undefined : `${reach} 2`} />}
          <circle cx={22.6} cy={y} r={1.9} fill="currentColor" opacity={Math.max(f.trackOpacity, clamp((reach - 0.9) / 0.1) * (phase === "starting" ? f.branchOpacity : 1))} />
        </g>;
      })}
      <circle cx={3.5} cy={12} r={2.4} fill="currentColor" />
      {car && (() => { const [x, y] = pointOnBranch(car.branch, car.at); return <circle cx={x} cy={y} r={2.5} fill="currentColor" opacity={car.opacity} />; })()}
    </g>
    <rect className="switch-stop" x={7.5} y={6.5} width={11} height={11} rx={2.5} fill="currentColor" />
  </svg>;
}

const help: Record<RoutingPhase, string> = {
  idle: "Start routing", starting: "Routing is starting",
  running: "Stops routing and removes the temporary Codex profile if this app created it.", stopping: "Routing is stopping",
};
const label: Record<RoutingPhase, string> = { idle: "Start routing", starting: "Starting routing", running: "Stop routing", stopping: "Stopping routing" };
/** The visible word names the action the control takes, or the one in flight. */
const word: Record<RoutingPhase, string> = { idle: "Start", starting: "Start", running: "Stop", stopping: "Stop" };

export function RoutingToggle({ phase, disabled, onToggle }: { phase: RoutingPhase; disabled: boolean; onToggle: () => void }) {
  const settled = phase === "idle" || phase === "running";
  return <button type="button" className={`routing-toggle ${phase}`} onClick={() => { if (settled) onToggle(); }} disabled={disabled}
    aria-disabled={!settled || undefined} title={disabled && phase === "idle" ? "Finish setup to start routing" : help[phase]} aria-label={label[phase]}>
    <SwitchGlyph phase={phase} />
    <span className="routing-toggle-word" aria-hidden="true">{word[phase]}</span>
  </button>;
}
