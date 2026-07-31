import { describe, expect, it } from "vitest";
import type { TindeqPreset } from "../types";
import type { ForceCurveModel } from "./force-curve";
import {
  alternatingCurveInputKey,
  alternatingHoldDurations,
  nextLockedAlternatingPrescription,
  prescriptionForSegment,
  resolveAlternatingPreset,
  resolveAlternatingRecommendation,
  targetHoldSegment,
} from "./alternatingProtocol";
import { buildTimeline } from "./protocol";

const left: ForceCurveModel = { points: [], maxF: 40, cf: 20, wPrime: 300 };
const right: ForceCurveModel = { points: [], maxF: 32, cf: 14, wPrime: 180 };
const inputs = {
  left: { model: left, prKg: 42 },
  right: { model: right, prKg: 33 },
};
const preset = (overrides: Partial<TindeqPreset>): TindeqPreset => ({
  id: "custom",
  name: "Custom",
  holdS: 10,
  holdsS: [10, 20, 8, 15],
  reps: 3,
  sets: 4,
  restRepsS: 60,
  restSetsS: 120,
  targetKg: null,
  targetPct: null,
  pctBasis: "pr",
  pctStep: 0,
  targetCurve: false,
  alternateSides: true,
  ...overrides,
});

describe("alternating force prescriptions (#331)", () => {
  it("resolves recommended load and hold independently for each hand", () => {
    const full = resolveAlternatingRecommendation(inputs, "strength", "FDP", 100, 4)!;
    const light = resolveAlternatingRecommendation(inputs, "strength", "FDP", 80, 4)!;
    expect(prescriptionForSegment(full, "left", 1)?.target?.kg).not.toBe(
      prescriptionForSegment(full, "right", 2)?.target?.kg,
    );
    expect(light.left.targets[0]!.kg).toBeCloseTo(full.left.targets[0]!.kg * 0.8, 1);
    expect(light.right.targets[0]!.kg).toBeCloseTo(full.right.targets[0]!.kg * 0.8, 1);
    const durations = alternatingHoldDurations(full)!;
    expect(durations.left).toEqual(Array(4).fill(full.left.targets[0]!.workS));
    expect(durations.right).toEqual(Array(4).fill(full.right.targets[0]!.workS));
    const holds = buildTimeline(full.protocol, {
      switchS: 3,
      alternatingHolds: durations,
    }).filter((segment) => segment.phase === "hold");
    expect(holds.slice(0, 4).map(({ side, durS }) => ({ side, durS }))).toEqual([
      { side: "left", durS: full.left.targets[0]!.workS },
      { side: "right", durS: full.right.targets[0]!.workS },
      { side: "left", durS: full.left.targets[0]!.workS },
      { side: "right", durS: full.right.targets[0]!.workS },
    ]);
  });

  it("rejects a recommendation when either hand cannot derive the zone", () => {
    expect(resolveAlternatingRecommendation({ ...inputs, right: { model: null, prKg: 33 } }, "strength", "FDP", 100, 2)).toBeNull();
    const noCf = { ...right, cf: null, wPrime: null };
    expect(resolveAlternatingRecommendation({ ...inputs, right: { model: noCf, prKg: 33 } }, "endurance", "FDP", 100, 2)).toBeNull();
  });

  it("resolves percent-PR ramps by actual hand and set", () => {
    const p = resolveAlternatingPreset(preset({ targetPct: 50, pctStep: 10 }), inputs)!;
    expect(prescriptionForSegment(p, "left", 1)?.target?.kg).toBe(21);
    expect(prescriptionForSegment(p, "right", 2)?.target?.kg).toBe(19.8);
    expect(prescriptionForSegment(p, "left", 3)?.hand.refs.prKg).toBe(42);
  });

  it("resolves percent-CF and smart-curve targets from each hand's refs per set", () => {
    const pct = resolveAlternatingPreset(preset({ targetPct: 80, pctBasis: "cf" }), inputs)!;
    expect(prescriptionForSegment(pct, "left", 1)?.target?.kg).toBe(16);
    expect(prescriptionForSegment(pct, "right", 2)?.target?.kg).toBe(11.2);
    const curve = resolveAlternatingPreset(preset({ targetCurve: true }), inputs)!;
    expect(prescriptionForSegment(curve, "left", 1)?.target?.kg).toBe(40);
    expect(prescriptionForSegment(curve, "right", 2)?.target?.kg).toBe(23);
  });

  it("requires missing refs only for reference-derived targets", () => {
    const missingRight = { ...inputs, right: { model: null, prKg: null } };
    expect(resolveAlternatingPreset(preset({ targetPct: 70 }), missingRight)).toBeNull();
    expect(resolveAlternatingPreset(preset({ targetCurve: true }), missingRight)).toBeNull();
    expect(resolveAlternatingPreset(preset({ targetKg: 25 }), missingRight)!.right.targets[1]!.kg).toBe(25);
    expect(resolveAlternatingPreset(preset({}), missingRight)!.right.targets[1]).toBeNull();
  });

  it("changes the curve key when a same-count candidate is replaced", () => {
    const row = {
      id: "left-a",
      recordedAt: "2026-07-31T00:00:00Z",
      durationMs: 7000,
      peakKg: 30,
    };
    const before = alternatingCurveInputKey("FDP", [row], []);
    const after = alternatingCurveInputKey("FDP", [{ ...row, id: "left-b" }], []);
    expect(after).not.toBe(before);
  });

  it("freezes while active and reuses an equal idle snapshot", () => {
    const locked = resolveAlternatingPreset(preset({ targetPct: 50 }), inputs)!;
    const equivalent = resolveAlternatingPreset(preset({ targetPct: 50 }), inputs)!;
    const changed = resolveAlternatingPreset(preset({ targetPct: 80 }), inputs)!;
    expect(nextLockedAlternatingPrescription(false, equivalent, locked)).toBe(locked);
    expect(nextLockedAlternatingPrescription(false, changed, locked)).toBe(changed);
    expect(nextLockedAlternatingPrescription(true, changed, locked)).toBe(locked);
  });

  it("uses the next actual hold's side and set during set-rest/switch", () => {
    const p = preset({ targetPct: 50, pctStep: 10 });
    const timeline = buildTimeline(p, { switchS: 3 });
    const setRest = timeline.find((s) => s.phase === "setRest" && s.set === 1)!;
    const nextFromRest = targetHoldSegment(timeline, setRest, false)!;
    expect({ side: nextFromRest.side, set: nextFromRest.set }).toEqual({ side: "left", set: 2 });
    const switchSeg = timeline.find((s) => s.phase === "switch")!;
    const nextFromSwitch = targetHoldSegment(timeline, switchSeg, false)!;
    expect({ side: nextFromSwitch.side, set: nextFromSwitch.set }).toEqual({ side: "right", set: 1 });
    const resolved = resolveAlternatingPreset(p, inputs)!;
    expect(prescriptionForSegment(resolved, nextFromRest.side, nextFromRest.set)?.target?.kg).toBe(25.2);
    expect(prescriptionForSegment(resolved, nextFromSwitch.side, nextFromSwitch.set)?.target?.kg).toBe(16.5);
  });
});
