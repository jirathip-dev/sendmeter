import { describe, it, expect } from "vitest";
import {
  buildPresetPlan,
  planLabelVisibility,
  planMetric,
  planVaries,
  presetHasTarget,
} from "./presetPlan";
import type { PlanPreset } from "./presetPlan";
import type { PresetRefs } from "./protocol";

const base: PlanPreset = {
  holdS: 7,
  holdsS: null,
  reps: 6,
  sets: 3,
  restRepsS: 3,
  restSetsS: 180,
  targetKg: null,
  targetPct: null,
  pctBasis: "pr",
  pctStep: 0,
  targetCurve: false,
  alternateSides: false,
};

const noRefs: PresetRefs = { prKg: null, cf: null, wPrime: null, maxF: null };

describe("buildPresetPlan / planVaries", () => {
  it("flat preset: all rows equal hold, planVaries false", () => {
    const rows = buildPresetPlan(base, noRefs);
    expect(rows.map((r) => r.holdS)).toEqual([7, 7, 7]);
    expect(planVaries(rows, base.sets)).toBe(false);
  });

  it("sets: 1 never varies, regardless of holdsS", () => {
    const p: PlanPreset = { ...base, sets: 1, holdsS: [5] };
    const rows = buildPresetPlan(p, noRefs);
    expect(planVaries(rows, p.sets)).toBe(false);
  });

  it("varying holdsS: rows carry each set's hold, planVaries true", () => {
    const p: PlanPreset = { ...base, holdsS: [5, 7, 9] };
    const rows = buildPresetPlan(p, noRefs);
    expect(rows.map((r) => r.holdS)).toEqual([5, 7, 9]);
    expect(planVaries(rows, p.sets)).toBe(true);
  });

  it("holdsS shorter than sets falls back to holdS for every row", () => {
    const p: PlanPreset = { ...base, holdsS: [5, 7] };
    const rows = buildPresetPlan(p, noRefs);
    expect(rows.map((r) => r.holdS)).toEqual([7, 7, 7]);
    expect(planVaries(rows, p.sets)).toBe(false);
  });

  it("alternating sides: L/R/L/R per setSide", () => {
    const p: PlanPreset = {
      ...base,
      sets: 4,
      holdsS: [7, 10, 7, 10],
      alternateSides: true,
    };
    const rows = buildPresetPlan(p, noRefs);
    expect(rows.map((r) => r.side)).toEqual(["left", "right", "left", "right"]);
    expect(planVaries(rows, p.sets)).toBe(true);
  });

  it("uses already-resolved per-hand/set targets for an alternating ramp", () => {
    const p: PlanPreset = {
      ...base,
      sets: 4,
      alternateSides: true,
      targetPct: 50,
      pctStep: 10,
    };
    const rows = buildPresetPlan(p, noRefs, [21, 19.8, 29.4, 26.4]);
    expect(rows.map(({ set, side, targetKg }) => ({ set, side, targetKg }))).toEqual([
      { set: 1, side: "left", targetKg: 21 },
      { set: 2, side: "right", targetKg: 19.8 },
      { set: 3, side: "left", targetKg: 29.4 },
      { set: 4, side: "right", targetKg: 26.4 },
    ]);
    expect(planVaries(rows, p.sets)).toBe(true);
  });

  it("non-alternating: side is null for every row", () => {
    const p: PlanPreset = { ...base, alternateSides: false };
    const rows = buildPresetPlan(p, noRefs);
    expect(rows.every((r) => r.side === null)).toBe(true);
  });

  it("targetCurve: target moves per set, lower for a longer hold, capped at maxF", () => {
    const p: PlanPreset = {
      ...base,
      holdsS: [1, 7, 20],
      targetCurve: true,
    };
    const refs: PresetRefs = { prKg: null, cf: 10, wPrime: 20, maxF: 25 };
    const rows = buildPresetPlan(p, refs);
    // CF + W'/hold: 1s -> 30, capped at maxF 25; 7s -> 10+20/7≈12.9; 20s -> 10+1=11
    expect(rows[0]!.targetKg).toBe(25);
    expect(rows[1]!.targetKg).toBeCloseTo(12.9, 1);
    expect(rows[2]!.targetKg).toBe(11);
    expect(rows[1]!.targetKg!).toBeGreaterThan(rows[2]!.targetKg!);
    expect(planVaries(rows, p.sets)).toBe(true);
  });

  it("%-ramp with pctStep > 0 ramps targets even with flat holds, capped at 150%", () => {
    const p: PlanPreset = { ...base, targetPct: 100, pctStep: 40, pctBasis: "pr" };
    const refs: PresetRefs = { prKg: 40, cf: null, wPrime: null, maxF: null };
    const rows = buildPresetPlan(p, refs);
    // set1: 100% of 40 = 40; set2: 140% = 56; set3: 180% capped 150% = 60
    expect(rows.map((r) => r.targetKg)).toEqual([40, 56, 60]);
    expect(planVaries(rows, p.sets)).toBe(true);
  });

  it("missing refs: every targetKg null, no throw", () => {
    const curve: PlanPreset = { ...base, targetCurve: true };
    const pct: PlanPreset = { ...base, targetPct: 60, pctBasis: "pr" };
    expect(() => buildPresetPlan(curve, noRefs)).not.toThrow();
    expect(() => buildPresetPlan(pct, noRefs)).not.toThrow();
    expect(buildPresetPlan(curve, noRefs).every((r) => r.targetKg === null)).toBe(true);
    expect(buildPresetPlan(pct, noRefs).every((r) => r.targetKg === null)).toBe(true);
  });

  it("fixed-kg mode: same target every set; flat holds -> planVaries false", () => {
    const p: PlanPreset = { ...base, targetKg: 30 };
    const rows = buildPresetPlan(p, noRefs);
    expect(rows.every((r) => r.targetKg === 30)).toBe(true);
    expect(planVaries(rows, p.sets)).toBe(false);
  });
});

describe("presetHasTarget", () => {
  it("Target load: None (no curve/pct/kg) has no target declared", () => {
    expect(presetHasTarget(base)).toBe(false);
  });

  it("curve mode declares a target even before refs resolve it", () => {
    expect(presetHasTarget({ ...base, targetCurve: true })).toBe(true);
  });

  it("%-of-PR mode declares a target even before a PR exists", () => {
    expect(presetHasTarget({ ...base, targetPct: 60 })).toBe(true);
  });

  it("fixed-kg mode declares a target", () => {
    expect(presetHasTarget({ ...base, targetKg: 30 })).toBe(true);
  });
});

describe("planMetric", () => {
  it("varying holds -> \"hold\", regardless of target", () => {
    const p: PlanPreset = { ...base, holdsS: [5, 7, 9] };
    const rows = buildPresetPlan(p, noRefs);
    expect(planMetric(rows)).toBe("hold");
  });

  it("flat holds + ramping %-of-PR target -> \"target\"", () => {
    const p: PlanPreset = { ...base, targetPct: 100, pctStep: 40 };
    const refs: PresetRefs = { prKg: 40, cf: null, wPrime: null, maxF: null };
    const rows = buildPresetPlan(p, refs);
    expect(planMetric(rows)).toBe("target");
  });

  it("flat holds + flat target -> \"target\" (moot: planVaries is false here anyway)", () => {
    const rows = buildPresetPlan(base, noRefs);
    expect(planMetric(rows)).toBe("target");
  });
});

describe("planLabelVisibility", () => {
  it("hides both labels once the bar+gap pitch is too narrow for either", () => {
    // 20-set maximum: barW ~11.6 + 4 gap ~ 15.6
    expect(planLabelVisibility(15.6)).toEqual({ showHold: false, showBelow: false });
  });

  it("shows only the (shorter) top label at a mid pitch", () => {
    // 10 sets: barW ~27 + 4 gap = 31
    expect(planLabelVisibility(31)).toEqual({ showHold: true, showBelow: false });
  });

  it("shows both labels once the pitch is wide enough for the longer one", () => {
    // 6 sets: barW ~48 + 4 gap = 52
    expect(planLabelVisibility(52)).toEqual({ showHold: true, showBelow: true });
  });
});
