import { describe, it, expect } from "vitest";
import {
  applyHoldEdit,
  buildTimeline,
  commitHoldEdit,
  curveHoldCopy,
  deriveHoldsField,
  firstHoldSide,
  formatKgRange,
  holdForSet,
  holdsForSets,
  holdsSummary,
  presetTargetKg,
  presetTargetKgRange,
  protocolBandLabel,
  protocolDurationS,
  timelineAt,
  timelineDurationS,
} from "./protocol";
import type { TindeqPreset } from "../types";

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
  const capabilityFit = { family: "hill" as const, cf: 20, maxF: 40, tau: 10, p: 1, sse: 1 };
  const refs = { prKg: 30, cf: 20, wPrime: 300, maxF: 40, capabilityFit };
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

  it("auto curve target evaluates the Hill capability fit", () => {
    const curve: TindeqPreset = { ...repeaters, holdS: 30, targetCurve: true };
    expect(presetTargetKg(curve, refs, 1)).toBe(25.5);
    expect(presetTargetKg({ ...curve, holdS: 7 }, refs, 1)).toBe(32.9);
    expect(presetTargetKg(curve, { ...refs, capabilityFit: null }, 1)).toBeNull();
    expect(presetTargetKg(curve, { ...refs, cf: null, wPrime: null }, 1)).toBe(25.5);
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
    const uncappedRefs = { ...refs };
    const curve: TindeqPreset = {
      ...repeaters,
      holdS: 5,
      holdsS: [5, 15, 30],
      sets: 3,
      targetCurve: true,
    };
    expect([1, 2, 3].map((set) => presetTargetKg(curve, uncappedRefs, set))).toEqual([34.7, 28.8, 25.5]);
    // a null-list preset keeps resolving off the single holdS, unchanged
    const uniform: TindeqPreset = { ...repeaters, holdS: 30, targetCurve: true };
    expect(presetTargetKg(uniform, refs, 1)).toBe(presetTargetKg(uniform, refs, 3));
  });
});

describe("presetTargetKgRange (#332 finding 2)", () => {
  const refs = { prKg: 30, cf: 20, wPrime: 300, maxF: 40, capabilityFit: { family: "hill" as const, cf: 20, maxF: 40, tau: 10, p: 1, sse: 1 } };

  it("collapses to a single value for a uniform preset", () => {
    const uniform: TindeqPreset = { ...repeaters, holdS: 30, targetCurve: true };
    expect(presetTargetKgRange(uniform, refs)).toEqual({ min: 25.5, max: 25.5 });
    expect(formatKgRange(presetTargetKgRange(uniform, refs)!)).toBe("25.5 kg");
  });

  it("spans min/max across sets for a monotonic per-set hold list", () => {
    // 5→15→30s holds → F = 20+300/5=80, 20+300/15=40, 20+300/30=30.
    const curve: TindeqPreset = { ...repeaters, holdS: 5, holdsS: [5, 15, 30], sets: 3, targetCurve: true };
    expect(presetTargetKgRange(curve, refs)).toEqual({ min: 25.5, max: 34.7 });
    expect(formatKgRange(presetTargetKgRange(curve, refs)!)).toBe("25.5–34.7 kg");
  });

  it("finds the extreme in a middle set — not just first/last (a non-monotonic list)", () => {
    // 15→5→30s holds → F = 20+300/15=40, 20+300/5=80, 20+300/30=30. The max
    // (80) sits at set 2, not at either end — a first/last shortcut would
    // have reported {min:30, max:40} and silently understated the range.
    const curve: TindeqPreset = { ...repeaters, holdS: 15, holdsS: [15, 5, 30], sets: 3, targetCurve: true };
    expect(presetTargetKgRange(curve, refs)).toEqual({ min: 25.5, max: 34.7 });
  });

  it("is null whenever presetTargetKg is (a needed reference isn't resolved yet)", () => {
    const curve: TindeqPreset = { ...repeaters, targetCurve: true };
    expect(presetTargetKgRange(curve, { ...refs, capabilityFit: null })).toBeNull();
  });
});

describe("curveHoldCopy (#332 round 6 finding c)", () => {
  it("states the exact single-hold formula when holds don't vary", () => {
    const copy = curveHoldCopy(false, 30);
    expect(copy.label).toBe("Hold time — 30s");
    expect(copy.description).toContain("Hill capability curve");
  });

  it("relabels as the base for overrideless sets, and drops the false single-hold formula, when varying", () => {
    const copy = curveHoldCopy(true, 30);
    expect(copy.label).toBe("Base hold time (sets without an override) — 30s");
    // Must not claim every set reads off exactly this one hold.
    expect(copy.description).not.toContain("CF + W′/30s");
    expect(copy.description).toContain("30s base");
  });
});

describe("protocolBandLabel (#332 round 6 finding a)", () => {
  it("renders the bare name for a uniform targetCurve preset — no duplicated kg", () => {
    // holdsS null (today's default) → min === max, so the parenthetical must
    // not appear even though sets > 1 and targetCurve is set.
    const uniform: TindeqPreset = { ...repeaters, holdS: 30, targetCurve: true };
    expect(protocolBandLabel(uniform, 30, 2, { min: 30, max: 30 })).toBe("Repeaters");
  });

  it("adds the set + range parenthetical only when holds actually vary", () => {
    const curve: TindeqPreset = { ...repeaters, holdS: 5, holdsS: [5, 15, 30], sets: 3, targetCurve: true };
    expect(protocolBandLabel(curve, 80, 1, { min: 30, max: 80 })).toBe(
      "Repeaters · set 1: 80.0 kg (30.0–80.0 kg)",
    );
  });

  it("renders the bare name for a targetCurve preset with a null range (ref not resolved)", () => {
    const curve: TindeqPreset = { ...repeaters, targetCurve: true };
    expect(protocolBandLabel(curve, 30, 1, null)).toBe("Repeaters");
  });

  it("keeps the existing %-of-PR ramp label unaffected (non-curve path)", () => {
    const ramp: TindeqPreset = { ...repeaters, sets: 4, targetKg: 20, targetPct: 50, pctStep: 10 };
    expect(protocolBandLabel(ramp, 18, 2, null)).toBe("Repeaters · set 2: 18.0 kg");
    expect(protocolBandLabel({ ...ramp, sets: 1 }, 15, 1, null)).toBe("Repeaters");
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

describe("commitHoldEdit (#332 round 6 finding b)", () => {
  it("committing the displayed value leaves the slot null — a focus+blur with no edit must not materialize it", () => {
    // NumInput.commit fires unconditionally on blur, even when the user only
    // tabbed/tapped through the field. Slot 1 is unset (null), following the
    // base holdS=7; committing that same displayed value (7) must be a no-op.
    const holds: (number | null)[] = [null, null, null];
    expect(commitHoldEdit(holds, 1, 7, 7)).toBe(holds); // same array, no write
  });

  it("a genuine edit to a different value still writes through", () => {
    const holds: (number | null)[] = [null, null, null];
    expect(commitHoldEdit(holds, 1, 20, 7)).toEqual([null, 20, null]);
  });

  it("re-committing an already-set slot's own value writes through (not gated by the unset check)", () => {
    // Slot 1 was previously typed to 20; committing 20 again (a legitimate
    // re-blur of an edited field) must still go through applyHoldEdit rather
    // than being silently skipped — the guard only applies to still-null slots.
    const holds: (number | null)[] = [null, 20, null];
    expect(commitHoldEdit(holds, 1, 20, 20)).toEqual([null, 20, null]);
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

  it("applies each set's duration to both hands when alternating", () => {
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
      { side: "right", durS: 5, set: 1 },
      { side: "left", durS: 5, set: 1 },
      { side: "right", durS: 5, set: 1 },
      { side: "left", durS: 9, set: 2 },
      { side: "right", durS: 9, set: 2 },
      { side: "left", durS: 9, set: 2 },
      { side: "right", durS: 9, set: 2 },
    ]);
  });
});

describe("buildTimeline — alternating every logical rep (#348)", () => {
  const holds = (p: TindeqPreset) => buildTimeline(p, { switchS: 3 }).filter((s) => s.phase === "hold");

  it("2 reps × 1 set produces L1,R1,L2,R2 and ends on the final right hold", () => {
    const tl = buildTimeline(alt, { switchS: 3 });
    expect(tl.filter((s) => s.phase === "hold").map((s) => [s.side, s.rep, s.set])).toEqual([
      ["left", 1, 1], ["right", 1, 1], ["left", 2, 1], ["right", 2, 1],
    ]);
    expect(tl.at(-1)).toMatchObject({ phase: "hold", side: "right", rep: 2, set: 1 });
  });

  it("gives both hands every rep in every one of 3 sets", () => {
    const hs = holds({ ...alt, reps: 2, sets: 3, restSetsS: 10 });
    expect(hs).toHaveLength(12);
    for (const set of [1, 2, 3]) {
      expect(hs.filter((h) => h.set === set).map((h) => [h.side, h.rep])).toEqual([
        ["left", 1], ["right", 1], ["left", 2], ["right", 2],
      ]);
    }
  });

  it("7s hold / 10s rest leaves only the 3s switch after the right hold", () => {
    const tl = buildTimeline({ ...alt, holdS: 7, restRepsS: 10 }, { switchS: 3 });
    expect(tl.map((s) => [s.phase, s.side, s.durS])).toEqual([
      ["hold", "left", 7], ["switch", "right", 3], ["hold", "right", 7],
      ["switch", "left", 3], ["hold", "left", 7], ["switch", "right", 3],
      ["hold", "right", 7],
    ]);
  });

  it("uses only switch time when hold is longer than rest", () => {
    const tl = buildTimeline({ ...alt, holdS: 12, restRepsS: 5 }, { switchS: 3 });
    expect(tl.some((s) => s.phase === "rest")).toBe(false);
    expect(tl.filter((s) => s.phase === "switch")).toHaveLength(3);
  });

  it("puts a long residual rest before the switch back to left", () => {
    const tl = buildTimeline({ ...alt, holdS: 5, restRepsS: 30 }, { switchS: 3 });
    expect(tl.slice(3, 5)).toMatchObject([
      { phase: "rest", durS: 22 },
      { phase: "switch", side: "left", durS: 3 },
    ]);
  });

  it("uses setRest arithmetic at a set boundary", () => {
    const tl = buildTimeline({ ...alt, reps: 1, sets: 2, holdS: 7, restSetsS: 20 }, { switchS: 3 });
    expect(tl.slice(3, 5)).toMatchObject([
      { phase: "setRest", durS: 10, rep: 1, set: 1 },
      { phase: "switch", side: "left", durS: 3 },
    ]);
    expect(holds({ ...alt, reps: 1, sets: 2, holdS: 7, restSetsS: 20 }).map((h) => [h.side, h.set])).toEqual([
      ["left", 1], ["right", 1], ["left", 2], ["right", 2],
    ]);
  });

  it("uses the current set's varying hold in boundary recovery arithmetic", () => {
    const p = { ...alt, reps: 1, sets: 2, holdS: 5, holdsS: [5, 12], restSetsS: 20 };
    const tl = buildTimeline(p, { switchS: 3 });
    expect(tl.filter((s) => s.phase === "hold").map((s) => s.durS)).toEqual([5, 5, 12, 12]);
    expect(tl.find((s) => s.phase === "setRest")?.durS).toBe(12);
  });

  it("uses independent hand holds without shortening either hand's recovery", () => {
    const p = { ...alt, reps: 2, sets: 1, holdS: 7, restRepsS: 30 };
    const tl = buildTimeline(p, {
      switchS: 3,
      alternatingHolds: { left: [12], right: [5] },
    });
    const hs = tl.filter((s) => s.phase === "hold");
    expect(hs.map((s) => [s.side, s.durS])).toEqual([
      ["left", 12],
      ["right", 5],
      ["left", 12],
      ["right", 5],
    ]);
    expect(tl.find((s) => s.phase === "rest")?.durS).toBe(22);
    const firstLeft = hs[0]!;
    const nextLeft = hs[2]!;
    const firstRight = hs[1]!;
    const nextRight = hs[3]!;
    expect(nextLeft.startS - (firstLeft.startS + firstLeft.durS)).toBeGreaterThanOrEqual(30);
    expect(nextRight.startS - (firstRight.startS + firstRight.durS)).toBeGreaterThanOrEqual(30);
  });

  it("preserves preparation before the first left hold", () => {
    const tl = buildTimeline(alt, { switchS: 3, prepareS: 5 });
    expect(tl.slice(0, 2)).toMatchObject([
      { phase: "prepare", side: null, durS: 5 },
      { phase: "hold", side: "left", rep: 1, set: 1 },
    ]);
  });

  it("keeps the exact non-alternating timeline unchanged", () => {
    expect(buildTimeline({ ...repeaters, sets: 2, reps: 2 })).toEqual([
      { phase: "hold", side: null, rep: 1, set: 1, startS: 0, durS: 7 },
      { phase: "rest", side: null, rep: 1, set: 1, startS: 7, durS: 3 },
      { phase: "hold", side: null, rep: 2, set: 1, startS: 10, durS: 7 },
      { phase: "setRest", side: null, rep: 2, set: 1, startS: 17, durS: 180 },
      { phase: "hold", side: null, rep: 1, set: 2, startS: 197, durS: 7 },
      { phase: "rest", side: null, rep: 1, set: 2, startS: 204, durS: 3 },
      { phase: "hold", side: null, rep: 2, set: 2, startS: 207, durS: 7 },
    ]);
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
