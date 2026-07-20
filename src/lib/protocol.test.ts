import { describe, it, expect } from "vitest";
import {
  buildTimeline,
  presetTargetKg,
  protocolDurationS,
  setSide,
  timelineAt,
  timelineDurationS,
} from "./protocol";
import type { TindeqPreset } from "../types";

// Classic repeaters: 7s hang / 3s rest × 6 reps, 3 sets, 180s between sets.
const repeaters: TindeqPreset = {
  id: "p1",
  name: "Repeaters",
  holdS: 7,
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

// The user's example: 5s holds, 30s rest, alternating hands.
const alt: TindeqPreset = {
  id: "p2",
  name: "Alt",
  holdS: 5,
  reps: 2,
  sets: 1,
  restRepsS: 30,
  restSetsS: 0,
  targetKg: null,
  targetPct: null,
  pctBasis: "pr",
  pctStep: 0,
  targetCurve: false,
  alternateSides: true,
};

describe("presetTargetKg", () => {
  // pr 30, cf 20, W' 300 (so F(7s) ≈ 20 + 300/7 ≈ 62.9, capped at maxF 40)
  const refs = { prKg: 30, cf: 20, wPrime: 300, maxF: 40 };
  const ramp: TindeqPreset = {
    ...repeaters,
    sets: 4,
    targetKg: 20,
    targetPct: 50,
    pctStep: 10,
  };

  it("ramps % of PR per set (50/60/70/80 of a 30kg PR)", () => {
    expect(presetTargetKg(ramp, refs, 1)).toBe(15);
    expect(presetTargetKg(ramp, refs, 2)).toBe(18);
    expect(presetTargetKg(ramp, refs, 3)).toBe(21);
    expect(presetTargetKg(ramp, refs, 4)).toBe(24);
  });

  it("clamps the set to the preset's range and the pct to 150", () => {
    expect(presetTargetKg(ramp, refs, 99)).toBe(24); // set clamped to 4
    expect(presetTargetKg({ ...ramp, targetPct: 140, pctStep: 20 }, refs, 4)).toBe(45); // 150% cap
  });

  it("%CF basis resolves against critical force, not PR", () => {
    // 90% of CF 20 = 18
    const cfPct: TindeqPreset = { ...ramp, sets: 1, targetPct: 90, pctStep: 0, pctBasis: "cf" };
    expect(presetTargetKg(cfPct, refs, 1)).toBe(18);
    // no CF → null
    expect(presetTargetKg(cfPct, { ...refs, cf: null }, 1)).toBeNull();
  });

  it("smart curve target = CF + W'/hold, capped at maxF", () => {
    const curve: TindeqPreset = { ...repeaters, holdS: 30, targetCurve: true };
    // 20 + 300/30 = 30
    expect(presetTargetKg(curve, refs, 1)).toBe(30);
    // short hold would exceed maxF → capped at 40
    expect(presetTargetKg({ ...curve, holdS: 7 }, refs, 1)).toBe(40);
    // needs CF + W'
    expect(presetTargetKg(curve, { ...refs, cf: null }, 1)).toBeNull();
  });

  it("%PR mode needs a PR; falls back to absolute kg when pct unset", () => {
    expect(presetTargetKg(ramp, { ...refs, prKg: null }, 1)).toBeNull();
    expect(presetTargetKg({ ...ramp, targetPct: null }, { ...refs, prKg: null }, 1)).toBe(20);
    expect(presetTargetKg({ ...ramp, targetPct: null, targetKg: null }, refs, 1)).toBeNull();
  });
});

describe("setSide", () => {
  it("alternates left/right per set", () => {
    expect(setSide(1)).toBe("left");
    expect(setSide(2)).toBe("right");
    expect(setSide(3)).toBe("left");
  });
});

describe("protocolDurationS", () => {
  it("sums holds, rep rests, and set rests", () => {
    // set work = 6*7 + 5*3 = 57; total = 3*57 + 2*180 = 531
    expect(protocolDurationS(repeaters)).toBe(531);
  });
});

describe("buildTimeline — single side", () => {
  const tl = buildTimeline(repeaters);

  it("matches the nominal duration", () => {
    expect(timelineDurationS(tl)).toBe(531);
  });

  it("starts holding rep 1 set 1", () => {
    const pos = timelineAt(tl, 0)!;
    expect(pos.seg).toMatchObject({ phase: "hold", rep: 1, set: 1, side: null });
    expect(pos.remaining).toBe(7);
  });

  it("transitions hold → rest → next rep", () => {
    expect(timelineAt(tl, 7)!.seg.phase).toBe("rest");
    expect(timelineAt(tl, 10)!.seg).toMatchObject({ phase: "hold", rep: 2 });
  });

  it("last rep of a set goes straight to set rest", () => {
    // set 1 work ends at 57s
    expect(timelineAt(tl, 56.5)!.seg).toMatchObject({ phase: "hold", rep: 6, set: 1 });
    const pos = timelineAt(tl, 57)!;
    expect(pos.seg.phase).toBe("setRest");
    expect(pos.remaining).toBe(180);
    expect(timelineAt(tl, 237)!.seg).toMatchObject({ phase: "hold", rep: 1, set: 2 });
  });

  it("is done at the total duration", () => {
    expect(timelineAt(tl, 531)).toBeNull();
    expect(timelineAt(tl, 530.5)!.seg).toMatchObject({ phase: "hold", rep: 6, set: 3 });
  });

  it("prepends a prepare segment when asked", () => {
    const withPrep = buildTimeline(repeaters, { prepareS: 5 });
    expect(timelineAt(withPrep, 2)!.seg.phase).toBe("prepare");
    expect(timelineAt(withPrep, 5)!.seg).toMatchObject({ phase: "hold", rep: 1 });
    expect(timelineDurationS(withPrep)).toBe(536);
  });
});

describe("buildTimeline — alternating sides (per SET, SL-78)", () => {
  const tl = buildTimeline(alt, { switchS: 3 });

  it("runs every rep of a set on the same hand", () => {
    expect(timelineAt(tl, 0)!.seg).toMatchObject({ phase: "hold", side: "left", rep: 1, set: 1 });
    const rest = timelineAt(tl, 5)!;
    expect(rest.seg.phase).toBe("rest");
    expect(rest.remaining).toBe(30);
    expect(timelineAt(tl, 35)!.seg).toMatchObject({ phase: "hold", side: "left", rep: 2 });
    expect(timelineDurationS(tl)).toBe(40);
    expect(timelineAt(tl, 40)).toBeNull();
  });

  it("switches hands at the end of the set rest", () => {
    const twoSets = buildTimeline({ ...alt, sets: 2, restSetsS: 60 }, { switchS: 3 });
    // set 1 ends at 40; setRest 40–97 (60 − 3 switch), switch → RIGHT 97–100
    const pos = timelineAt(twoSets, 40)!;
    expect(pos.seg.phase).toBe("setRest");
    expect(pos.remaining).toBe(57);
    expect(timelineAt(twoSets, 98)!.seg).toMatchObject({ phase: "switch", side: "right" });
    expect(timelineAt(twoSets, 100)!.seg).toMatchObject({
      phase: "hold",
      side: "right",
      rep: 1,
      set: 2,
    });
    expect(timelineDurationS(twoSets)).toBe(140);
  });

  it("auto-extends a set rest too short for the switch window", () => {
    const tight = buildTimeline({ ...alt, sets: 2, restSetsS: 1 }, { switchS: 3 });
    // effective rest = max(1, 3) = 3 → all switch, no idle setRest
    expect(timelineAt(tight, 41)!.seg).toMatchObject({ phase: "switch", side: "right" });
    expect(timelineAt(tight, 43)!.seg).toMatchObject({ phase: "hold", side: "right", set: 2 });
  });

  it("odd sets are left, even sets right", () => {
    const three = buildTimeline({ ...alt, sets: 3, restSetsS: 10 }, { switchS: 3 });
    const holds = three.filter((s) => s.phase === "hold");
    expect(holds.map((h) => h.side)).toEqual([
      "left", "left", "right", "right", "left", "left",
    ]);
  });
});
