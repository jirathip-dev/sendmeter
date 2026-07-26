import { describe, it, expect, beforeEach, vi } from "vitest";
import {
  applyIntensity,
  buildZoneSelection,
  loadIntensity,
  saveIntensity,
  selectedQuality,
  QUALITY_COLORS,
  type ZoneSelection,
} from "./zoneSelection";
import { ZONE_INTENSITY, type ForceCurveModel } from "./force-curve";

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
    const model: ForceCurveModel = { points: [], maxF: 40, cf: 20, wPrime: 300 };
    const result = buildZoneSelection(model, "strength", "FDP L", true);
    expect(result).toEqual<ZoneSelection>({
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
});

describe("applyIntensity", () => {
  const model: ForceCurveModel = { points: [], maxF: 40, cf: 20, wPrime: 300 };
  const custom: ZoneSelection = {
    target: { kg: 30, lowKg: 28, highKg: 32, workS: 10, label: "Custom" },
    protocol: {
      id: "custom-1",
      name: "Custom",
      holdS: 10,
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
      target: { kg: 30, lowKg: 28, highKg: 32, workS: 10, label: "Strength" },
      protocol: {
        id: "zone:strength",
        name: "Strength",
        holdS: 10,
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
      target: { kg: 30, lowKg: 28, highKg: 32, workS: 10, label: "Custom" },
      protocol: {
        id: "custom-1",
        name: "Custom",
        holdS: 10,
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
      target: { kg: 30, lowKg: 28, highKg: 32, workS: 10, label: "Bogus" },
      protocol: {
        id: "zone:bogus",
        name: "Bogus",
        holdS: 10,
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
});
