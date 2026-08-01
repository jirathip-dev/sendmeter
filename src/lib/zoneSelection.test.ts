import { describe, it, expect, beforeEach, vi } from "vitest";
import {
  applyIntensity,
  armedAlternates,
  armedForDifferentTag,
  buildPrehabSelection,
  buildWarmupSelection,
  buildZoneSelection,
  chartSideFor,
  loadIntensity,
  performedQuality,
  protocolQuality,
  rederiveSelection,
  saveIntensity,
  selectedQuality,
  zoneColor,
  QUALITY_COLORS,
  type ZoneSelection,
} from "./zoneSelection";
import {
  PREHAB_PROTOCOL,
  WARMUP_PROTOCOL,
  ZONE_INTENSITY,
  type ForceCurveModel,
} from "./force-curve";
import { classifyZone, classifyZoneLoaded } from "./zoneHistory";
import { presetTargetKg } from "./protocol";
import type { TindeqPreset } from "../types";

const INTENSITY_KEY = "sendmeter:zone-intensity";

/// In-memory stand-in for localStorage — keeps these tests jsdom-free
/// (this project's vitest config runs in node), mirroring
/// recordingQueue.test.ts's "jsdom-free, in-memory stand-in" convention.
function fakeStorage(): Storage {
  const map = new Map<string, string>();
  return {
    getItem: (k: string) => map.get(k) ?? null,
    setItem: (k: string, v: string) => void map.set(k, v),
    removeItem: (k: string) => void map.delete(k),
    clear: () => map.clear(),
    key: () => null,
    length: 0,
  } as Storage;
}

describe("buildZoneSelection", () => {
  it("returns null when there is no model", () => {
    expect(buildZoneSelection(null, "strength", "FDP L", true)).toBeNull();
  });

  it("returns null when the model can't derive the zone (no CF)", () => {
    const noCf: ForceCurveModel = { points: [], maxF: 40, cf: null, wPrime: null };
    // endurance and power-endurance both require a CF fit (see zoneTarget).
    expect(buildZoneSelection(noCf, "endurance", "FDP L", true)).toBeNull();
    expect(buildZoneSelection(noCf, "power-endurance", "FDP L", true)).toBeNull();
  });

  it("assembles the target + protocol for a representative model", () => {
    const model: ForceCurveModel = { points: [], maxF: 40, cf: 20, wPrime: 300, capabilityFit: { family: "hill", cf: 20, maxF: 40, tau: 10, p: 1, sse: 1 } };
    const result = buildZoneSelection(model, "strength", "FDP L", true);
    expect(result).toEqual<ZoneSelection>({
      tag: "FDP L",
      target: {
        kg: 34,
        lowKg: 32,
        highKg: 36,
        workS: 10,
        label: "Strength · FDP L",
      },
      protocol: {
        id: "zone:strength",
        name: "Strength · FDP L",
        holdS: 10,
        holdsS: null,
        reps: 5,
        sets: 1,
        restRepsS: 150,
        restSetsS: 0,
        targetKg: 34,
        targetPct: null,
        pctBasis: "pr",
        pctStep: 0,
        targetCurve: false,
        alternateSides: true,
      },
    });
  });

  it("alt=false threads alternateSides:false through", () => {
    const model: ForceCurveModel = { points: [], maxF: 40, cf: 20, wPrime: 300 };
    const result = buildZoneSelection(model, "strength", "FDP L", false);
    expect(result!.protocol.alternateSides).toBe(false);
  });

  it("#332 no-regression: leaves holdsS null for every recommended quality", () => {
    const model: ForceCurveModel = { points: [], maxF: 40, cf: 20, wPrime: 300, capabilityFit: { family: "hill", cf: 20, maxF: 40, tau: 10, p: 1, sse: 1 } };
    for (const q of ["power", "strength", "power-endurance", "endurance"] as const) {
      expect(buildZoneSelection(model, q, "FDP L", true)!.protocol.holdsS).toBeNull();
    }
  });
});

describe("buildPrehabSelection (#325)", () => {
  it("returns null when there is no model", () => {
    expect(buildPrehabSelection(null, "FDP L")).toBeNull();
  });

  it("returns null when the model can't derive a target (no CF, no usable maxF)", () => {
    const dead: ForceCurveModel = { points: [], maxF: 0, cf: null, wPrime: null };
    expect(buildPrehabSelection(dead, "FDP L")).toBeNull();
  });

  it("assembles the target + protocol at 0.70 × CF, single-sided", () => {
    const model: ForceCurveModel = { points: [], maxF: 40, cf: 20, wPrime: 300 };
    const result = buildPrehabSelection(model, "FDP L")!;
    expect(result.tag).toBe("FDP L");
    expect(result.target.kg).toBeCloseTo(14, 5); // 20 × 0.70
    expect(result.target.workS).toBe(PREHAB_PROTOCOL.holdS);
    expect(result.protocol).toMatchObject({
      id: "zone:prehab",
      holdS: PREHAB_PROTOCOL.holdS,
      reps: PREHAB_PROTOCOL.reps,
      sets: PREHAB_PROTOCOL.sets,
      restRepsS: PREHAB_PROTOCOL.restRepsS,
      restSetsS: PREHAB_PROTOCOL.restSetsS,
      targetKg: 14,
      alternateSides: false,
    });
  });

  it("falls back to 0.30 × maxF without a CF fit", () => {
    const noCf: ForceCurveModel = { points: [], maxF: 40, cf: null, wPrime: null };
    const result = buildPrehabSelection(noCf, "FDP L")!;
    expect(result.target.kg).toBeCloseTo(12, 5); // 40 × 0.30
  });

  it("#332 no-regression: leaves holdsS null", () => {
    const model: ForceCurveModel = { points: [], maxF: 40, cf: 20, wPrime: 300 };
    expect(buildPrehabSelection(model, "FDP L")!.protocol.holdsS).toBeNull();
  });
});

describe("buildWarmupSelection (#297)", () => {
  it("returns null without a usable force reference", () => {
    expect(buildWarmupSelection(null, "FDP L")).toBeNull();
    expect(
      buildWarmupSelection(
        { points: [], maxF: 0, cf: null, wPrime: null },
        "FDP L",
      ),
    ).toBeNull();
  });

  it("assembles progressive holds and a 40% → 70% PR load ramp", () => {
    const model: ForceCurveModel = { points: [], maxF: 40, cf: 20, wPrime: 300 };
    const result = buildWarmupSelection(model, "FDP L")!;
    expect(result.target.kg).toBe(16);
    expect(result.protocol).toMatchObject({
      id: "zone:warmup",
      holdS: 5,
      holdsS: [5, 7, 10],
      reps: 2,
      sets: 3,
      restRepsS: 15,
      restSetsS: 60,
      targetKg: null,
      targetPct: 40,
      pctBasis: "pr",
      pctStep: 15,
      alternateSides: false,
    });
    const refs = { prKg: 40, cf: 20, wPrime: 300, maxF: 40 };
    expect([1, 2, 3].map((set) => presetTargetKg(result.protocol, refs, set))).toEqual([
      16,
      22,
      28,
    ]);
    expect(result.protocol.holdsS).toEqual(WARMUP_PROTOCOL.holdsS);
  });
});

describe("applyIntensity", () => {
  const model: ForceCurveModel = { points: [], maxF: 40, cf: 20, wPrime: 300 };
  const custom: ZoneSelection = {
    tag: "FDP L",
    target: { kg: 30, lowKg: 28, highKg: 32, workS: 10, label: "Custom" },
    protocol: {
      id: "custom-1",
      name: "Custom",
      holdS: 10,
      holdsS: null,
      reps: 5,
      sets: 1,
      restRepsS: 150,
      restSetsS: 0,
      targetKg: 30,
      targetPct: null,
      pctBasis: "pr",
      pctStep: 0,
      targetCurve: false,
      alternateSides: true,
    },
  };

  it("re-derives an armed zone at the new intensity", () => {
    const armed = buildZoneSelection(model, "strength", "FDP L", false, 100)!;
    const lighter = applyIntensity(armed, model, "FDP L", 80)!;
    expect(lighter.target.kg).toBeCloseTo(armed.target.kg * 0.8, 5);
    expect(lighter.protocol.targetKg).toBe(lighter.target.kg);
    // Lighter load ⇒ the hold is extended to keep the dose equivalent.
    expect(lighter.protocol.holdS).toBeGreaterThan(armed.protocol.holdS);
  });

  it("preserves the zone's alternate-sides setting", () => {
    const armed = buildZoneSelection(model, "strength", "FDP L", true, 100)!;
    expect(applyIntensity(armed, model, "FDP L", 90)!.protocol.alternateSides).toBe(true);
  });

  it("leaves a custom preset completely untouched (the dial is zones-only)", () => {
    // The boundary that matters: PresetManager presets keep the load the user
    // configured no matter where the intensity dial sits.
    expect(applyIntensity(custom, model, "FDP L", 60)).toBe(custom);
    expect(applyIntensity(custom, model, "FDP L", 110)).toBe(custom);
  });

  it("passes a null selection through", () => {
    expect(applyIntensity(null, model, "FDP L", 80)).toBeNull();
  });

  it("keeps the current selection when the zone can no longer be derived", () => {
    const armed = buildZoneSelection(model, "endurance", "FDP L", false, 100)!;
    const noCf: ForceCurveModel = { points: [], maxF: 40, cf: null, wPrime: null };
    // Endurance needs a CF fit — rather than silently disarming, keep it armed.
    expect(applyIntensity(armed, noCf, "FDP L", 80)).toBe(armed);
    expect(applyIntensity(armed, null, "FDP L", 80)).toBe(armed);
    expect(applyIntensity(armed, model, null, 80)).toBe(armed);
  });

  it("leaves an armed Prehab selection completely untouched (#325 — the dial is recommended-zones-only)", () => {
    // Prehab's sub-CF load and 30s dose are both load-bearing (Baar's
    // window); the dial scaling either would break the guarantee. Prehab has
    // no TrainingQuality of its own, so `selectedQuality` returns null for it
    // and it takes the exact same "untouched" path a custom preset does.
    const prehab = buildPrehabSelection(model, "FDP L")!;
    expect(applyIntensity(prehab, model, "FDP L", 60)).toBe(prehab);
    expect(applyIntensity(prehab, model, "FDP L", 110)).toBe(prehab);
  });

  it("leaves an armed Warm-up selection untouched — its progression is fixed", () => {
    const warmup = buildWarmupSelection(model, "FDP L")!;
    expect(applyIntensity(warmup, model, "FDP L", 60)).toBe(warmup);
    expect(applyIntensity(warmup, model, "FDP L", 110)).toBe(warmup);
  });
});

describe("rederiveSelection (#298)", () => {
  const model: ForceCurveModel = { points: [], maxF: 40, cf: 20, wPrime: 300 };
  const custom: ZoneSelection = {
    tag: "FDP L",
    target: { kg: 30, lowKg: 28, highKg: 32, workS: 10, label: "Custom" },
    protocol: {
      id: "custom-1",
      name: "Custom",
      holdS: 10,
      holdsS: null,
      reps: 5,
      sets: 1,
      restRepsS: 150,
      restSetsS: 0,
      targetKg: 30,
      targetPct: null,
      pctBasis: "pr",
      pctStep: 0,
      targetCurve: false,
      alternateSides: true,
    },
  };

  it("rebuilds the target kg + label for a new tag at the current intensity", () => {
    const armed = buildZoneSelection(model, "strength", "FDP L", false, 100)!;
    const rederived = rederiveSelection(armed, model, "FDP R", 100)!;
    expect(rederived.target.label).toBe("Strength · FDP R");
    expect(rederived.protocol.name).toBe("Strength · FDP R");
    expect(rederived.target.kg).toBe(armed.target.kg); // same model, same math
  });

  it("preserves quality and alternateSides across the switch", () => {
    const armed = buildZoneSelection(model, "power", "FDP L", true, 100)!;
    const rederived = rederiveSelection(armed, model, "FDP R", 100)!;
    expect(selectedQuality(rederived)).toBe("power");
    expect(rederived.protocol.alternateSides).toBe(true);
  });

  it("holds the current selection when the model is null (not fitted yet, not a rejection)", () => {
    // A null model means "no curve to derive against right now" (still
    // fitting, or a fetch failure) — not "this zone is rejected". Disarming
    // here would drop the guided UI/gauge band mid-run whenever the curve
    // recompute is frozen (SL-80) and a tag switch flips `tagSideKey`.
    const armed = buildZoneSelection(model, "strength", "FDP L", false, 100)!;
    expect(rederiveSelection(armed, null, "FDP R", 100)).toBe(armed);
  });

  it("returns null (disarms) when the new tag's zone can't be derived (no CF)", () => {
    const armed = buildZoneSelection(model, "endurance", "FDP L", false, 100)!;
    const noCf: ForceCurveModel = { points: [], maxF: 40, cf: null, wPrime: null };
    expect(rederiveSelection(armed, noCf, "FDP R", 100)).toBeNull();
  });

  it("returns null (disarms) when there's no tag to derive against", () => {
    const armed = buildZoneSelection(model, "strength", "FDP L", false, 100)!;
    expect(rederiveSelection(armed, model, null, 100)).toBeNull();
  });

  it("passes a null selection through", () => {
    expect(rederiveSelection(null, model, "FDP R", 100)).toBeNull();
  });

  it("leaves a custom-preset-shaped selection untouched", () => {
    expect(rederiveSelection(custom, model, "FDP R", 100)).toBe(custom);
  });

  describe("Prehab (#325)", () => {
    it("rebuilds at the new tag, keeping the load at 0.70×CF for THAT tag", () => {
      const armed = buildPrehabSelection(model, "FDP L")!;
      const otherModel: ForceCurveModel = { points: [], maxF: 80, cf: 40, wPrime: 300 };
      const rederived = rederiveSelection(armed, otherModel, "FDP R", 100)!;
      expect(protocolQuality(rederived.protocol)).toBe("prehab");
      expect(rederived.target.kg).toBeCloseTo(28, 5); // 40 × 0.70, the NEW tag's CF
      expect(rederived.protocol.holdS).toBe(30); // dose never varies
    });

    it("holds the current selection when the model is null (still fitting, not a rejection)", () => {
      const armed = buildPrehabSelection(model, "FDP L")!;
      expect(rederiveSelection(armed, null, "FDP R", 100)).toBe(armed);
    });

    it("returns null (disarms) when there's no tag to derive against", () => {
      const armed = buildPrehabSelection(model, "FDP L")!;
      expect(rederiveSelection(armed, model, null, 100)).toBeNull();
    });

    it("returns null (disarms) when the new tag can't derive a Prehab target", () => {
      const armed = buildPrehabSelection(model, "FDP L")!;
      const dead: ForceCurveModel = { points: [], maxF: 0, cf: null, wPrime: null };
      expect(rederiveSelection(armed, dead, "FDP R", 100)).toBeNull();
    });
  });

  describe("Warm-up (#297)", () => {
    it("rebuilds the PR preview for the new tag while preserving the fixed ramp", () => {
      const armed = buildWarmupSelection(model, "FDP L")!;
      const otherModel: ForceCurveModel = { points: [], maxF: 80, cf: 40, wPrime: 300 };
      const rederived = rederiveSelection(armed, otherModel, "FDP R", 100)!;
      expect(protocolQuality(rederived.protocol)).toBe("warmup");
      expect(rederived.target.kg).toBe(32);
      expect(rederived.protocol.holdsS).toEqual([5, 7, 10]);
      expect(rederived.protocol.targetPct).toBe(40);
      expect(rederived.protocol.pctStep).toBe(15);
    });
  });
});

describe("loadIntensity / saveIntensity", () => {
  beforeEach(() => {
    vi.stubGlobal("localStorage", fakeStorage());
  });

  it("returns the default when nothing is stored", () => {
    expect(loadIntensity()).toBe(ZONE_INTENSITY.default);
  });

  it("returns a valid parsed value", () => {
    localStorage.setItem(INTENSITY_KEY, JSON.stringify(90));
    expect(loadIntensity()).toBe(90);
  });

  it("falls back to default on malformed JSON", () => {
    localStorage.setItem(INTENSITY_KEY, "{not json");
    expect(loadIntensity()).toBe(ZONE_INTENSITY.default);
  });

  it("falls back to default on the wrong type", () => {
    localStorage.setItem(INTENSITY_KEY, JSON.stringify("90"));
    expect(loadIntensity()).toBe(ZONE_INTENSITY.default);
  });

  it("falls back to default when out of range (above max)", () => {
    localStorage.setItem(INTENSITY_KEY, JSON.stringify(ZONE_INTENSITY.max + 1));
    expect(loadIntensity()).toBe(ZONE_INTENSITY.default);
  });

  it("falls back to default when out of range (below min)", () => {
    localStorage.setItem(INTENSITY_KEY, JSON.stringify(ZONE_INTENSITY.min - 1));
    expect(loadIntensity()).toBe(ZONE_INTENSITY.default);
  });

  it("falls back to default on a stale per-quality map (regression guard)", () => {
    // Before SL-97b, intensity was stored per-quality as an object; loading
    // that shape now must not be mistaken for a valid number.
    localStorage.setItem(
      INTENSITY_KEY,
      JSON.stringify({ power: 90, strength: 100 }),
    );
    expect(loadIntensity()).toBe(ZONE_INTENSITY.default);
  });

  it("accepts the exact min/max boundary values", () => {
    localStorage.setItem(INTENSITY_KEY, JSON.stringify(ZONE_INTENSITY.min));
    expect(loadIntensity()).toBe(ZONE_INTENSITY.min);
    localStorage.setItem(INTENSITY_KEY, JSON.stringify(ZONE_INTENSITY.max));
    expect(loadIntensity()).toBe(ZONE_INTENSITY.max);
  });

  it("round-trips through saveIntensity", () => {
    saveIntensity(80);
    expect(loadIntensity()).toBe(80);
  });
});

describe("selectedQuality", () => {
  it("parses the quality out of a zone:* id", () => {
    const sel: ZoneSelection = {
      tag: "FDP",
      target: { kg: 30, lowKg: 28, highKg: 32, workS: 10, label: "Strength" },
      protocol: {
        id: "zone:strength",
        name: "Strength",
        holdS: 10,
        holdsS: null,
        reps: 5,
        sets: 1,
        restRepsS: 150,
        restSetsS: 0,
        targetKg: 30,
        targetPct: null,
        pctBasis: "pr",
        pctStep: 0,
        targetCurve: false,
        alternateSides: true,
      },
    };
    expect(selectedQuality(sel)).toBe("strength");
    expect(Object.keys(QUALITY_COLORS)).toContain(selectedQuality(sel));
  });

  it("returns null for a custom-preset id (no zone: prefix)", () => {
    const sel: ZoneSelection = {
      tag: "FDP",
      target: { kg: 30, lowKg: 28, highKg: 32, workS: 10, label: "Custom" },
      protocol: {
        id: "custom-1",
        name: "Custom",
        holdS: 10,
        holdsS: null,
        reps: 5,
        sets: 1,
        restRepsS: 150,
        restSetsS: 0,
        targetKg: 30,
        targetPct: null,
        pctBasis: "pr",
        pctStep: 0,
        targetCurve: false,
        alternateSides: true,
      },
    };
    expect(selectedQuality(sel)).toBeNull();
  });

  it("returns null for an unknown quality (matches zone: prefix but not a real quality key)", () => {
    const sel: ZoneSelection = {
      tag: "FDP",
      target: { kg: 30, lowKg: 28, highKg: 32, workS: 10, label: "Bogus" },
      protocol: {
        id: "zone:bogus",
        name: "Bogus",
        holdS: 10,
        holdsS: null,
        reps: 5,
        sets: 1,
        restRepsS: 150,
        restSetsS: 0,
        targetKg: 30,
        targetPct: null,
        pctBasis: "pr",
        pctStep: 0,
        targetCurve: false,
        alternateSides: true,
      },
    };
    expect(selectedQuality(sel)).toBeNull();
  });

  it("returns null for a null selection", () => {
    expect(selectedQuality(null)).toBeNull();
  });

  it("returns null for an armed Prehab selection (#325) — it has no TrainingQuality", () => {
    const model: ForceCurveModel = { points: [], maxF: 40, cf: 20, wPrime: 300 };
    const prehab = buildPrehabSelection(model, "FDP")!;
    expect(protocolQuality(prehab.protocol)).toBe("prehab"); // it IS a recorded zone…
    expect(selectedQuality(prehab)).toBeNull(); // …but not a trainable one
  });

  it("returns null for an armed Warm-up selection — it has no TrainingQuality", () => {
    const model: ForceCurveModel = { points: [], maxF: 40, cf: 20, wPrime: 300 };
    const warmup = buildWarmupSelection(model, "FDP")!;
    expect(protocolQuality(warmup.protocol)).toBe("warmup");
    expect(selectedQuality(warmup)).toBeNull();
  });
});

describe("zoneColor (#325)", () => {
  it("matches QUALITY_COLORS for the four trainable qualities", () => {
    for (const q of Object.keys(QUALITY_COLORS) as (keyof typeof QUALITY_COLORS)[]) {
      expect(zoneColor(q)).toBe(QUALITY_COLORS[q]);
    }
  });

  it("gives Prehab a muted color that isn't in QUALITY_COLORS", () => {
    expect(zoneColor("prehab")).toBe("var(--ink-muted)");
    expect(Object.values(QUALITY_COLORS)).not.toContain(zoneColor("prehab"));
  });

  it("gives Warm-up a distinct maintenance color", () => {
    expect(zoneColor("warmup")).toBe("var(--primary)");
    expect(Object.values(QUALITY_COLORS)).not.toContain(zoneColor("warmup"));
  });
});

describe("performedQuality (#259)", () => {
  /// A custom preset, i.e. one whose id is NOT `zone:${q}` — it declares no
  /// quality of its own, so its zone has to be classified from hold + load.
  function customPreset(over: Partial<TindeqPreset> = {}): TindeqPreset {
    return {
      id: "preset-uuid",
      name: "My hangs",
      holdS: 7,
      holdsS: null,
      reps: 5,
      sets: 3,
      restRepsS: 150,
      restSetsS: 180,
      targetKg: 34,
      targetPct: null,
      pctBasis: "pr",
      pctStep: 0,
      targetCurve: false,
      alternateSides: false,
      ...over,
    };
  }

  const refs = { maxF: 40, cf: 20 };

  it("records an armed zone's own quality, whatever its numbers would classify as", () => {
    const model: ForceCurveModel = { points: [], maxF: 40, cf: 20, wPrime: 500 };
    const sel = buildZoneSelection(model, "strength", "FDP", false)!;
    expect(sel).not.toBeNull();
    expect(performedQuality(sel.protocol, sel.protocol.targetKg, refs, 1)).toBe(
      "strength",
    );
    // …and it is the zone the user armed, not a re-derivation: even fed
    // deliberately contradictory references it still answers strength.
    expect(
      performedQuality(sel.protocol, 1, { maxF: 1000, cf: 900 }, 1),
    ).toBe("strength");
  });

  it("records a custom preset's LOAD-AWARE badge, which duration alone would get wrong", () => {
    // 7s at 34kg of a 40kg max = 85% → Strength on the preset's badge…
    const p = customPreset({ holdS: 7, targetKg: 34 });
    expect(performedQuality(p, 34, refs, 1)).toBe("strength");
    // …while a duration-only re-derivation of the saved 7s hold says Power
    // Endurance. That divergence is the bug #259 exists to close.
    expect(classifyZone(7)).toBe("power-endurance");
  });

  it("matches classifyZoneLoaded exactly — the same call PresetManager's badge makes", () => {
    const p = customPreset({ holdS: 10 });
    for (const kg of [null, 15, 24, 34, 38]) {
      expect(performedQuality(p, kg, refs, 1)).toBe(
        classifyZoneLoaded(p.holdS, kg, refs),
      );
    }
  });

  it("classifies a custom preset per SET, so a ramp can move the zone", () => {
    // %-of-PR with a per-set step: set 1 at 70% of 40kg is power-endurance,
    // set 3 at 90% is strength. The saved rep gets its own set's answer.
    const p = customPreset({ holdS: 10, targetKg: null, targetPct: 70, pctStep: 10 });
    expect(
      performedQuality(p, presetTargetKg(p, { ...refs, prKg: 40, wPrime: null }, 1), refs, 1),
    ).toBe("power-endurance");
    expect(
      performedQuality(p, presetTargetKg(p, { ...refs, prKg: 40, wPrime: null }, 3), refs, 3),
    ).toBe("strength");
  });

  it("classifies a varying hold list at that set's OWN hold (#332), not the base holdS", () => {
    // Same 34kg load (≥0.8·maxF of 40) at set 1's 5s hold classifies as
    // Strength; at set 3's 25s hold — past the 20s Strength/Power-Endurance
    // cutoff — the identical load classifies as Endurance instead.
    const p = customPreset({
      holdS: 5,
      holdsS: [5, 12, 25],
      targetKg: 34,
      targetPct: null,
    });
    expect(performedQuality(p, 34, refs, 1)).toBe("strength");
    expect(performedQuality(p, 34, refs, 3)).toBe("endurance");
    expect(performedQuality(p, 34, refs, 1)).toBe(classifyZoneLoaded(5, 34, refs));
    expect(performedQuality(p, 34, refs, 3)).toBe(classifyZoneLoaded(25, 34, refs));
  });

  it("falls back to duration for an untargeted preset with no resolvable load", () => {
    const p = customPreset({ holdS: 12, targetKg: null });
    expect(performedQuality(p, null, refs, 1)).toBe(classifyZone(12));
  });

  it("records nothing at all for a freehand hold (no protocol armed)", () => {
    expect(performedQuality(null, 34, refs, 1)).toBeNull();
  });

  it("records 'prehab' for a hold performed under an armed Prehab protocol (#325), never falling through to classifyZoneLoaded", () => {
    const model: ForceCurveModel = { points: [], maxF: 40, cf: 20, wPrime: 300 };
    const prehab = buildPrehabSelection(model, "FDP")!;
    expect(performedQuality(prehab.protocol, prehab.protocol.targetKg, refs, 1)).toBe("prehab");
    // A 30s hold with no recorded zone infers as Endurance — proof that
    // skipping the stamp here would silently credit training balance with
    // exactly the thing #325 exists to keep out of it.
    expect(classifyZone(prehab.protocol.holdS)).toBe("endurance");
  });

  it("records 'warmup' for every set despite its changing duration and load", () => {
    const model: ForceCurveModel = { points: [], maxF: 40, cf: 20, wPrime: 300 };
    const warmup = buildWarmupSelection(model, "FDP")!;
    const targetRefs = { ...refs, prKg: 40, wPrime: 300 };
    for (const set of [1, 2, 3]) {
      expect(
        performedQuality(
          warmup.protocol,
          presetTargetKg(warmup.protocol, targetRefs, set),
          refs,
          set,
        ),
      ).toBe("warmup");
    }
  });
});

describe("armedAlternates / chartSideFor (#298)", () => {
  function altPreset(alternateSides: boolean): TindeqPreset {
    return {
      id: "preset-1",
      name: "Custom",
      holdS: 10,
      holdsS: null,
      reps: 5,
      sets: 1,
      restRepsS: 150,
      restSetsS: 0,
      targetKg: 30,
      targetPct: null,
      pctBasis: "pr",
      pctStep: 0,
      targetCurve: false,
      alternateSides,
    };
  }
  function altZoneSel(alternateSides: boolean): ZoneSelection {
    return {
      tag: "FDP",
      target: { kg: 30, lowKg: 28, highKg: 32, workS: 10, label: "Strength" },
      protocol: { ...altPreset(alternateSides), id: "zone:strength", name: "Strength" },
    };
  }

  describe("armedAlternates", () => {
    it("reads a custom preset's own flag", () => {
      expect(armedAlternates(altPreset(true), null)).toBe(true);
      expect(armedAlternates(altPreset(false), null)).toBe(false);
    });

    it("reads an armed zone's own flag when no preset is armed", () => {
      expect(armedAlternates(null, altZoneSel(true))).toBe(true);
      expect(armedAlternates(null, altZoneSel(false))).toBe(false);
    });

    it("prefers the preset when (in principle) both are set — mutual exclusivity is enforced elsewhere", () => {
      expect(armedAlternates(altPreset(true), altZoneSel(false))).toBe(true);
    });

    it("is false with nothing armed (a free hold)", () => {
      expect(armedAlternates(null, null)).toBe(false);
    });
  });

  describe("chartSideFor", () => {
    it("is null (all sides) whenever the armed protocol alternates, regardless of the picked side", () => {
      expect(chartSideFor(true, "left")).toBeNull();
      expect(chartSideFor(true, "right")).toBeNull();
      expect(chartSideFor(true, "both")).toBeNull();
      expect(chartSideFor(true, "")).toBeNull();
    });

    it("passes a concrete left/right pick through when nothing alternates", () => {
      expect(chartSideFor(false, "left")).toBe("left");
      expect(chartSideFor(false, "right")).toBe("right");
    });

    it("treats '' and 'both' as all-sides even when nothing alternates", () => {
      expect(chartSideFor(false, "")).toBeNull();
      expect(chartSideFor(false, "both")).toBeNull();
    });
  });
});

describe("armedForDifferentTag (#298 round 6, finding 3)", () => {
  const model: ForceCurveModel = { points: [], maxF: 40, cf: 20, wPrime: 300 };

  it("is false when nothing is armed", () => {
    expect(armedForDifferentTag(null, "FDP")).toBe(false);
  });

  it("is false when the armed zone matches the current tag", () => {
    const armed = buildZoneSelection(model, "strength", "FDP", false)!;
    expect(armedForDifferentTag(armed, "FDP")).toBe(false);
  });

  it("is true when ticking alternate flips the tag out from under a single-side selection", () => {
    // The #298 round 6 repro: armed under "FDP · left", then the checkbox
    // flips alternateSides on — chartSideFor goes all-sides, so the LIVE
    // zoneTag becomes plain "FDP" while the just-armed selection still says
    // "FDP · left".
    const armed = buildZoneSelection(model, "strength", "FDP · left", true)!;
    expect(armedForDifferentTag(armed, "FDP")).toBe(true);
  });

  it("is true for an ordinary tag switch with a zone still armed", () => {
    const armed = buildZoneSelection(model, "strength", "FDP", false)!;
    expect(armedForDifferentTag(armed, "hip rotation")).toBe(true);
  });
});
