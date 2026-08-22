import { describe, expect, it } from "vitest";
import {
  adaptiveHoldDurationMs,
  adaptiveStaticHolds,
  armAdaptiveStatic,
  stepAdaptiveStatic,
  type AdaptiveStaticState,
} from "./adaptiveStaticProtocol";
import { DEFAULT_HANDS_FREE_FORCE_CONFIG } from "./handsFreeForce";
import type { ProtocolSegment } from "./protocol";

const cfg = {
  ...DEFAULT_HANDS_FREE_FORCE_CONFIG,
  startKg: 2,
  stopKg: 1,
  startStableMs: 100,
  stopGraceMs: 200,
};
const timeline: ProtocolSegment[] = [
  { phase: "hold", side: "left", rep: 1, set: 1, startS: 0, durS: 1 },
  { phase: "rest", side: null, rep: 1, set: 1, startS: 1, durS: 2 },
  { phase: "hold", side: "right", rep: 1, set: 1, startS: 3, durS: 1 },
];
const holds = adaptiveStaticHolds(timeline);

function step(state: ReturnType<typeof armAdaptiveStatic>, atMs: number, kg: number) {
  return stepAdaptiveStatic(state, holds, { atMs, kg }, cfg);
}

describe("adaptive static protocol", () => {
  it("ignores noisy crossings and starts only after stable load", () => {
    let s = armAdaptiveStatic();
    ({ state: s } = step(s, 0, 2.1));
    ({ state: s } = step(s, 50, 1.9));
    ({ state: s } = step(s, 60, 2.1));
    const result = step(s, 160, 2.1);
    expect(result.action).toMatchObject({ type: "start", holdIndex: 0 });
  });

  it("allows a brief dip but fails at the original release timestamp when grace crosses the deadline", () => {
    let s = armAdaptiveStatic();
    ({ state: s } = step(s, 0, 3));
    ({ state: s } = step(s, 100, 3));
    ({ state: s } = step(s, 900, 0));
    ({ state: s } = step(s, 1_000, 3));
    ({ state: s } = step(s, 1_050, 0));
    const failed = step(s, 1_250, 0);
    expect(failed.action).toMatchObject({ type: "save", outcome: "failed", endedMs: 1_050, actualDurationMs: 950 });
  });

  it("completes when release begins at or after the prescribed deadline", () => {
    let atDeadline: AdaptiveStaticState = {
      phase: "hold",
      holdIndex: 0,
      startedMs: 100,
      belowSinceMs: null,
      lastMs: 100,
    };
    const exact = stepAdaptiveStatic(atDeadline, holds, { atMs: 1_100, kg: 0 }, cfg);
    expect(exact.action).toMatchObject({ type: "save", outcome: "good", endedMs: 1_100 });

    atDeadline = {
      phase: "hold",
      holdIndex: 0,
      startedMs: 100,
      belowSinceMs: null,
      lastMs: 100,
    };
    const after = stepAdaptiveStatic(atDeadline, holds, { atMs: 1_250, kg: 0 }, cfg);
    expect(after.action).toMatchObject({ type: "save", outcome: "good", endedMs: 1_100 });
  });

  it("saves success at planned duration, requires unload, then accepts a stable pull before rest expiry", () => {
    let s = armAdaptiveStatic();
    ({ state: s } = step(s, 0, 3));
    ({ state: s } = step(s, 100, 3));
    const success = step(s, 1_100, 3);
    expect(success.action).toMatchObject({ type: "save", outcome: "good", actualDurationMs: 1_000 });
    s = success.state;
    expect(step(s, 1_300, 3).action).toBeNull();
    ({ state: s } = step(s, 1_400, 0));
    ({ state: s } = step(s, 1_500, 3));
    expect(step(s, 1_600, 3).action).toMatchObject({ type: "start", holdIndex: 1 });
  });

  it("waits after recovery expiry until an unloaded stable pull", () => {
    let s = armAdaptiveStatic();
    ({ state: s } = step(s, 0, 3));
    ({ state: s } = step(s, 100, 3));
    ({ state: s } = step(s, 1_100, 3));
    expect(step(s, 5_000, 3).action).toBeNull();
    ({ state: s } = step(s, 5_010, 0));
    ({ state: s } = step(s, 5_020, 3));
    expect(step(s, 5_120, 3).action).toMatchObject({ type: "start", holdIndex: 1 });
  });

  it("preserves alternating metadata and completes exactly once after final hold", () => {
    expect(holds.map((h) => [h.set, h.rep, h.side])).toEqual([[1, 1, "left"], [1, 1, "right"]]);
    const s = { phase: "hold", holdIndex: 1, startedMs: 10, belowSinceMs: null, lastMs: 10 } as const;
    const done = stepAdaptiveStatic(s, holds, { atMs: 1_010, kg: 3 }, cfg);
    expect(done.action).toMatchObject({ type: "save", holdIndex: 1, outcome: "good" });
    expect(done.state).toMatchObject({ phase: "complete", failed: false });
    expect(stepAdaptiveStatic(done.state, holds, { atMs: 2_000, kg: 3 }, cfg).action).toBeNull();
  });

  it("keeps a final early release visibly failed while completing exactly once", () => {
    let s: AdaptiveStaticState = {
      phase: "hold",
      holdIndex: 1,
      startedMs: 10,
      belowSinceMs: null,
      lastMs: 10,
    };
    ({ state: s } = stepAdaptiveStatic(s, holds, { atMs: 500, kg: 0 }, cfg));
    const done = stepAdaptiveStatic(s, holds, { atMs: 700, kg: 0 }, cfg);
    expect(done.action).toMatchObject({
      type: "save",
      holdIndex: 1,
      outcome: "failed",
      endedMs: 500,
    });
    expect(done.state).toMatchObject({ phase: "complete", failed: true });
    expect(stepAdaptiveStatic(done.state, holds, { atMs: 900, kg: 0 }, cfg).action).toBeNull();
  });

  it("rounds a fractional hold span to an integer duration, floored at 1ms", () => {
    expect(adaptiveHoldDurationMs(0, 12.345)).toBe(12);
    expect(adaptiveHoldDurationMs(100.1, 1_100.9)).toBe(1_001);
    expect(adaptiveHoldDurationMs(0, 0.2)).toBe(1);
    expect(adaptiveHoldDurationMs(0, 0)).toBe(1);
  });

  it("clamps backward timestamps and never emits an action twice", () => {
    let s = armAdaptiveStatic(100);
    ({ state: s } = step(s, 100, 3));
    expect(step(s, 50, 3).action).toBeNull();
    const started = step(s, 200, 3);
    expect(started.action?.type).toBe("start");
    expect(stepAdaptiveStatic(started.state, holds, { atMs: 200, kg: 3 }, cfg).action).toBeNull();
  });
});
