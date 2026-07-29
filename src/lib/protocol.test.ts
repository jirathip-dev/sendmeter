import { describe, it, expect } from "vitest";
import {
  applyHoldEdit,
  buildTimeline,
  deriveHoldsField,
  firstHoldSide,
  formatKgRange,
  holdForSet,
  holdsForSets,
  holdsSummary,
  presetTargetKg,
  presetTargetKgRange,
  protocolDurationS,
  setSide,
  timelineAt,
  timelineDurationS,
} from "./protocol";
import type { TindeqPreset } from "../types";
import { ZONE_PROTOCOLS } from "./force-curve";

// Classic repeaters: 7s hang / 3s rest × 6 reps, 3 sets, 180s between sets.
const repeaters: TindeqPreset = {
  id: "p1",
  name: "Repeaters",
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

// The user's example: 5s holds, 30s rest, alternating hands.
const alt: TindeqPreset = {
  id: "p2",
  name: "Alt",
  holdS: 5,
  holdsS: null,
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

  it("smart curve target resolves against THAT SET's hold (#332), not the base holdS", () => {
    // 5→15→30s holds; CF 20, W' 300 → F = 20 + 300/hold. A generous maxF
    // (100) keeps the cap from masking the per-set difference this test is
    // about.
    const uncappedRefs = { prKg: 30, cf: 20, wPrime: 300, maxF: 100 };
    const curve: TindeqPreset = {
      ...repeaters,
      holdS: 5,
      holdsS: [5, 15, 30],
      sets: 3,
      targetCurve: true,
    };
    expect(presetTargetKg(curve, uncappedRefs, 1)).toBeCloseTo(20 + 300 / 5, 1);
    expect(presetTargetKg(curve, uncappedRefs, 2)).toBeCloseTo(20 + 300 / 15, 1);
    expect(presetTargetKg(curve, uncappedRefs, 3)).toBeCloseTo(20 + 300 / 30, 1);
    // a null-list preset keeps resolving off the single holdS, unchanged
    const uniform: TindeqPreset = { ...repeaters, holdS: 30, targetCurve: true };
    expect(presetTargetKg(uniform, refs, 1)).toBe(presetTargetKg(uniform, refs, 3));
  });
});

describe("presetTargetKgRange (#332 finding 2)", () => {
  const refs = { prKg: 30, cf: 20, wPrime: 300, maxF: 100 };

  it("collapses to a single value for a uniform preset", () => {
    const uniform: TindeqPreset = { ...repeaters, holdS: 30, targetCurve: true };
    expect(presetTargetKgRange(uniform, refs)).toEqual({ min: 30, max: 30 });
    expect(formatKgRange(presetTargetKgRange(uniform, refs)!)).toBe("30.0 kg");
  });

  it("spans min/max across sets for a monotonic per-set hold list", () => {
    // 5→15→30s holds → F = 20+300/5=80, 20+300/15=40, 20+300/30=30.
    const curve: TindeqPreset = { ...repeaters, holdS: 5, holdsS: [5, 15, 30], sets: 3, targetCurve: true };
    expect(presetTargetKgRange(curve, refs)).toEqual({ min: 30, max: 80 });
    expect(formatKgRange(presetTargetKgRange(curve, refs)!)).toBe("30.0–80.0 kg");
  });

  it("finds the extreme in a middle set — not just first/last (a non-monotonic list)", () => {
    // 15→5→30s holds → F = 20+300/15=40, 20+300/5=80, 20+300/30=30. The max
    // (80) sits at set 2, not at either end — a first/last shortcut would
    // have reported {min:30, max:40} and silently understated the range.
    const curve: TindeqPreset = { ...repeaters, holdS: 15, holdsS: [15, 5, 30], sets: 3, targetCurve: true };
    expect(presetTargetKgRange(curve, refs)).toEqual({ min: 30, max: 80 });
  });

  it("is null whenever presetTargetKg is (a needed reference isn't resolved yet)", () => {
    const curve: TindeqPreset = { ...repeaters, targetCurve: true };
    expect(presetTargetKgRange(curve, { ...refs, cf: null })).toBeNull();
  });
});

describe("setSide", () => {
  it("alternates left/right per set", () => {
    expect(setSide(1)).toBe("left");
    expect(setSide(2)).toBe("right");
    expect(setSide(3)).toBe("left");
  });
});

describe("holdForSet (#332)", () => {
  it("falls back to holdS when holdsS is null", () => {
    expect(holdForSet(repeaters, 1)).toBe(7);
    expect(holdForSet(repeaters, 3)).toBe(7);
  });

  it("falls back to holdS when holdsS is shorter than sets", () => {
    const short: TindeqPreset = { ...repeaters, holdsS: [5, 6] }; // sets: 3
    expect(holdForSet(short, 1)).toBe(7);
    expect(holdForSet(short, 2)).toBe(7);
    expect(holdForSet(short, 3)).toBe(7);
  });

  it("resolves per-set values from an exact-length list", () => {
    const varying: TindeqPreset = { ...repeaters, holdsS: [5, 7, 9] };
    expect(holdForSet(varying, 1)).toBe(5);
    expect(holdForSet(varying, 2)).toBe(7);
    expect(holdForSet(varying, 3)).toBe(9);
  });

  it("clamps set below 1 to the first set and above sets to the last", () => {
    const varying: TindeqPreset = { ...repeaters, holdsS: [5, 7, 9] };
    expect(holdForSet(varying, 0)).toBe(5);
    expect(holdForSet(varying, -3)).toBe(5);
    expect(holdForSet(varying, 4)).toBe(9);
    expect(holdForSet(varying, 99)).toBe(9);
  });
});

describe("holdsForSets (#332)", () => {
  it("returns holdS for every set when null", () => {
    expect(holdsForSets(repeaters)).toEqual([7, 7, 7]);
  });

  it("returns the resolved per-set list when varying", () => {
    const varying: TindeqPreset = { ...repeaters, holdsS: [5, 7, 9] };
    expect(holdsForSets(varying)).toEqual([5, 7, 9]);
  });
});

describe("deriveHoldsField (#332 preset-editor derivation)", () => {
  it("saves null when the checkbox is off, regardless of typed holds", () => {
    expect(deriveHoldsField(false, 7, [5, 9, 12], 3)).toEqual({
      holdBase: 7,
      holdsS: null,
      resolved: [5, 9, 12],
    });
  });

  it("saves null when the checkbox is on but every resolved slot is equal", () => {
    // no slots typed yet — every slot falls back to holdS, so it's uniform.
    expect(deriveHoldsField(true, 7, [], 3)).toEqual({
      holdBase: 7,
      holdsS: null,
      resolved: [7, 7, 7],
    });
    // explicitly typed, but all the same value.
    expect(deriveHoldsField(true, 7, [7, 7, 7], 3)).toEqual({
      holdBase: 7,
      holdsS: null,
      resolved: [7, 7, 7],
    });
  });

  it("saves the resolved list and stamps holdBase to set 1 when it varies", () => {
    expect(deriveHoldsField(true, 7, [5, 7, 9], 3)).toEqual({
      holdBase: 5,
      holdsS: [5, 7, 9],
      resolved: [5, 7, 9],
    });
  });

  it("unset slots (shorter `holds`) fall back to holdS", () => {
    expect(deriveHoldsField(true, 7, [5], 3)).toEqual({
      holdBase: 5,
      holdsS: [5, 7, 7],
      resolved: [5, 7, 7],
    });
  });

  it("extra slots (longer `holds`, e.g. after lowering sets) are ignored", () => {
    expect(deriveHoldsField(true, 7, [5, 6, 9, 20], 2)).toEqual({
      holdBase: 5,
      holdsS: [5, 6],
      resolved: [5, 6],
    });
  });
});

describe("applyHoldEdit (#332 round 2 finding 1)", () => {
  it("overwrites one slot without touching the others", () => {
    expect(applyHoldEdit([5, 7, 9], 1, 20)).toEqual([5, 20, 9]);
  });

  it("preserves a shrink-edit-grow round trip — editing after lowering `sets` must not drop the tail", () => {
    // Sets=4, holds typed as [5,10,15,20]; lower Sets to 2 (the form still
    // holds the full array — `sets` alone changed), then edit Set 1's field.
    let holds: (number | null)[] = [5, 10, 15, 20];
    holds = applyHoldEdit(holds, 0, 9);
    // The 15 and 20 typed for sets 3/4 must survive, not get reseeded from
    // holdS when `sets` is raised back to 4.
    expect(holds).toEqual([9, 10, 15, 20]);
    expect(deriveHoldsField(true, 7, holds, 4).resolved).toEqual([9, 10, 15, 20]);
  });
});

describe("applyHoldEdit + deriveHoldsField (#332 round 3 finding 1)", () => {
  it("an untouched slot keeps following the base holdS — editing one slot must not freeze the others", () => {
    // Sets=3, nothing typed yet; edit Set 3 only.
    let holds: (number | null)[] = [];
    holds = applyHoldEdit(holds, 2, 30);
    expect(deriveHoldsField(true, 7, holds, 3).resolved).toEqual([7, 7, 30]);

    // Now the base changes — the two untouched slots must follow it, not
    // stay frozen at the 7 that was live when Set 3 was edited.
    expect(deriveHoldsField(true, 60, holds, 3)).toEqual({
      holdBase: 60,
      holdsS: [60, 60, 30],
      resolved: [60, 60, 30],
    });
  });

  it("editing every slot to match the base saves null (no spurious variation)", () => {
    let holds: (number | null)[] = [];
    holds = applyHoldEdit(holds, 0, 7);
    holds = applyHoldEdit(holds, 1, 7);
    holds = applyHoldEdit(holds, 2, 7);
    expect(deriveHoldsField(true, 7, holds, 3)).toEqual({
      holdBase: 7,
      holdsS: null,
      resolved: [7, 7, 7],
    });
  });
});

describe("holdsSummary formatting (#332 finding 2)", () => {
  it("formats a uniform long hold in m/s, like the rest column beside it", () => {
    const long: TindeqPreset = { ...repeaters, holdS: 240, holdsS: null };
    expect(holdsSummary(long)).toBe("4m");
  });

  it("formats each element of a varying summary in m/s", () => {
    const varying: TindeqPreset = { ...repeaters, holdsS: [5, 70, 240] };
    expect(holdsSummary(varying)).toBe("5s→1m10s→4m");
  });
});

describe("protocolDurationS", () => {
  it("sums holds, rep rests, and set rests", () => {
    // set work = 6*7 + 5*3 = 57; total = 3*57 + 2*180 = 531
    expect(protocolDurationS(repeaters)).toBe(531);
  });

  it("sums PER-SET holds when they vary (#332)", () => {
    // NOT [5, 7, 9] — that averages to exactly repeaters.holdS (7), so the
    // pre-#332 formula `sets * (reps*holdS + …)` coincidentally returns the
    // same 531 total and this test would pass without the fix. [5, 7, 12]
    // sums to something the old, holdS-only formula cannot produce.
    const varying: TindeqPreset = { ...repeaters, holdsS: [5, 7, 12] };
    // set work = 6*5+5*3=45, 6*7+5*3=57, 6*12+5*3=87; total = 45+57+87 + 2*180 = 549
    expect(protocolDurationS(varying)).toBe(549);
    expect(protocolDurationS(varying)).toBe(timelineDurationS(buildTimeline(varying)));
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

describe("buildTimeline — byte-identical regression (#332's main risk)", () => {
  it("a null holdsS produces the exact same timeline as before this field existed", () => {
    expect(buildTimeline(repeaters)).toEqual(buildTimeline({ ...repeaters, holdsS: null }));
    expect(buildTimeline(alt, { switchS: 3 })).toEqual(
      buildTimeline({ ...alt, holdsS: null }, { switchS: 3 }),
    );
  });

  it("an exact-length uniform holdsS produces the identical timeline to the null-list preset", () => {
    const uniform: TindeqPreset = { ...repeaters, holdsS: [7, 7, 7] };
    expect(buildTimeline(uniform)).toEqual(buildTimeline(repeaters));
  });

  it("a holdsS shorter than sets is ignored — identical to null", () => {
    const short: TindeqPreset = { ...repeaters, holdsS: [5, 6] };
    expect(buildTimeline(short)).toEqual(buildTimeline(repeaters));
  });
});

describe("buildTimeline — varying per-set holds (#332)", () => {
  it("emits each set's holds at that set's duration, with correct accumulation", () => {
    // holdS:5 fallback, holdsS:[5,7,9], sets:3, reps:2, no rests-between-reps
    // (restRepsS:0) to keep the arithmetic simple; restSetsS:0 too.
    const varying: TindeqPreset = {
      ...repeaters,
      holdS: 5,
      holdsS: [5, 7, 9],
      sets: 3,
      reps: 2,
      restRepsS: 0,
      restSetsS: 0,
    };
    const tl = buildTimeline(varying);
    const holds = tl.filter((s) => s.phase === "hold");
    expect(holds.map((h) => h.durS)).toEqual([5, 5, 7, 7, 9, 9]);
    expect(holds.map((h) => h.startS)).toEqual([0, 5, 10, 17, 24, 33]);
    expect(timelineDurationS(tl)).toBe(42);
  });

  it("keeps per-set sides and switch segments when alternating with varying holds", () => {
    const varying: TindeqPreset = {
      ...alt,
      holdsS: [5, 9],
      sets: 2,
      restSetsS: 60,
      alternateSides: true,
    };
    const tl = buildTimeline(varying, { switchS: 3 });
    const holds = tl.filter((s) => s.phase === "hold");
    expect(holds.map((h) => ({ side: h.side, durS: h.durS, set: h.set }))).toEqual([
      { side: "left", durS: 5, set: 1 },
      { side: "left", durS: 5, set: 1 },
      { side: "right", durS: 9, set: 2 },
      { side: "right", durS: 9, set: 2 },
    ]);
    const switches = tl.filter((s) => s.phase === "switch");
    expect(switches).toHaveLength(1);
    expect(switches[0]).toMatchObject({ side: "right", durS: 3 });
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

describe("endurance preset — 1 rep × 8 sets (#320)", () => {
  // ZONE_PROTOCOLS.endurance flipped from 8 reps × 1 set to 1 rep × 8 sets so
  // per-SET alternation actually fires; buildTimeline alternates per set, so
  // sets: 1 meant "Alternate left ⇄ right" was a no-op before this change.
  const endurance: TindeqPreset = {
    id: "endurance",
    name: "Endurance",
    holdS: ZONE_PROTOCOLS.endurance.holdS,
    holdsS: null,
    reps: ZONE_PROTOCOLS.endurance.reps,
    sets: ZONE_PROTOCOLS.endurance.sets,
    restRepsS: ZONE_PROTOCOLS.endurance.restRepsS,
    restSetsS: ZONE_PROTOCOLS.endurance.restSetsS,
    targetKg: null,
    targetPct: null,
    pctBasis: "pr",
    pctStep: 0,
    targetCurve: false,
    alternateSides: false,
  };

  it("non-alternating: 8×30s holds separated by 7×30s gaps, 450s total — byte-for-byte the old 8×1 shape's effect", () => {
    const tl = buildTimeline(endurance);
    const holds = tl.filter((s) => s.phase === "hold");
    const gaps = tl.filter((s) => s.phase === "setRest" || s.phase === "rest");
    expect(holds).toHaveLength(8);
    expect(holds.every((h) => h.durS === 30)).toBe(true);
    expect(gaps).toHaveLength(7);
    expect(gaps.every((g) => g.durS === 30)).toBe(true);
    // gaps are now labeled setRest (between sets), not rest (between reps) —
    // a legitimate label change, not a timing change.
    expect(gaps.every((g) => g.phase === "setRest")).toBe(true);
    expect(timelineDurationS(tl)).toBe(450);
  });

  it("alternating: sides flip every hold, gaps split into 27s rest + 3s switch, still 450s total", () => {
    const tl = buildTimeline({ ...endurance, alternateSides: true }, { switchS: 3 });
    const holds = tl.filter((s) => s.phase === "hold");
    expect(holds.map((h) => h.side)).toEqual([
      "left", "right", "left", "right", "left", "right", "left", "right",
    ]);
    expect(holds.every((h) => h.durS === 30)).toBe(true);
    const setRests = tl.filter((s) => s.phase === "setRest");
    const switches = tl.filter((s) => s.phase === "switch");
    expect(setRests).toHaveLength(7);
    expect(setRests.every((r) => r.durS === 27)).toBe(true);
    expect(switches).toHaveLength(7);
    expect(switches.every((s) => s.durS === 3)).toBe(true);
    expect(timelineDurationS(tl)).toBe(450);
  });
});

describe("firstHoldSide (#298)", () => {
  it("finds the first hold's side even when a prepare segment (side: null) comes first", () => {
    // The default-on get-ready countdown (prepareS: 5) puts a `side: null`
    // prepare segment at index 0 — `segs[0].side` would wrongly read null
    // for an alternating protocol that's idle, dimming every side chip.
    const tl = buildTimeline(alt, { prepareS: 5 });
    expect(tl[0]!.phase).toBe("prepare");
    expect(tl[0]!.side).toBeNull();
    expect(firstHoldSide(tl)).toBe("left");
  });

  it("finds the first hold's side with no prepare segment", () => {
    const tl = buildTimeline(alt, { prepareS: 0 });
    expect(tl[0]!.phase).toBe("hold");
    expect(firstHoldSide(tl)).toBe("left");
  });

  it("is null for a non-alternating protocol (holds carry no side of their own)", () => {
    const tl = buildTimeline(repeaters, { prepareS: 5 });
    expect(firstHoldSide(tl)).toBeNull();
  });

  it("is null for an empty timeline", () => {
    expect(firstHoldSide([])).toBeNull();
  });
});
