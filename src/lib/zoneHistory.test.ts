import { describe, expect, it } from "vitest";
import {
  classifyZone,
  classifyZoneLoaded,
  dominantZone,
  recommendZone,
  zoneSets,
  zoneTrainingSets,
} from "./zoneHistory";
import type { ForceCurveModel } from "./force-curve";

describe("classifyZone (SL-100)", () => {
  it("buckets by hold duration around the zone anchors", () => {
    expect(classifyZone(0.5)).toBeNull();
    expect(classifyZone(5)).toBe("power");
    expect(classifyZone(6)).toBe("power");
    expect(classifyZone(7)).toBe("power-endurance");
    expect(classifyZone(8.5)).toBe("power-endurance");
    expect(classifyZone(10)).toBe("strength");
    expect(classifyZone(20)).toBe("strength");
    expect(classifyZone(30)).toBe("endurance");
    expect(classifyZone(90)).toBe("endurance");
  });
});

describe("classifyZoneLoaded (SL-97b)", () => {
  const refs = { maxF: 40, cf: 20 };

  it("falls back to the duration-only classifier with no resolved kg", () => {
    expect(classifyZoneLoaded(7, null, refs)).toBe(classifyZone(7));
    expect(classifyZoneLoaded(10, null, refs)).toBe(classifyZone(10));
  });

  it("falls back to the duration-only classifier with no maxF", () => {
    expect(classifyZoneLoaded(10, 34, { maxF: null, cf: 20 })).toBe(classifyZone(10));
  });

  it("still returns null for a sub-1s blip regardless of load", () => {
    expect(classifyZoneLoaded(0.5, 34, refs)).toBeNull();
  });

  it("≤ critical force is always endurance, even at a short hold", () => {
    // 15kg is below CF 20 — a hold this light is sustainable, not powerful,
    // no matter how short the hold happened to be.
    expect(classifyZoneLoaded(5, 15, refs)).toBe("endurance");
    expect(classifyZoneLoaded(5, 20, refs)).toBe("endurance"); // == CF counts too
  });

  it("power: ≥90% maxF and ≤6s", () => {
    expect(classifyZoneLoaded(5, 37, refs)).toBe("power"); // 0.925 · maxF
    expect(classifyZoneLoaded(6, 36, refs)).toBe("power"); // exactly 0.9 · maxF
  });

  it("strength: ≥80% maxF and ≤20s (worked example: maxF 40, cf 20, 10s @ 34kg)", () => {
    // Threshold matches the Strength zone's own band low (zoneTarget: 0.8·maxF,
    // #105/SL-103) so a preset only badges Strength when it actually reaches
    // that zone's load.
    expect(classifyZoneLoaded(10, 34, refs)).toBe("strength"); // 0.85 · maxF
    expect(classifyZoneLoaded(20, 32, refs)).toBe("strength"); // exactly 0.8 · maxF
  });

  it("a load just under the Strength band falls to power-endurance, not a fuzzy Strength badge", () => {
    // 30kg = 0.75·maxF — under the old (incidental) 0.75 threshold this
    // badged "Strength" despite sitting below the zone's own 0.8 low; it now
    // re-badges Power Endurance, which matches what the load actually is.
    expect(classifyZoneLoaded(20, 30, refs)).toBe("power-endurance");
  });

  it("power-endurance: above CF but under the power/strength thresholds, ≤20s", () => {
    expect(classifyZoneLoaded(10, 24, refs)).toBe("power-endurance"); // 0.6 · maxF
    expect(classifyZoneLoaded(5, 24, refs)).toBe("power-endurance"); // short but under 0.9 · maxF
  });

  it("endurance: above CF and > 20s, even without a strength-level load", () => {
    expect(classifyZoneLoaded(25, 24, refs)).toBe("endurance");
  });

  it("re-classifies live as the resolved load drops at a fixed hold time", () => {
    // The worked example from the PR: maxF 40, cf 20, hold fixed at 10s.
    expect(classifyZoneLoaded(10, 34, refs)).toBe("strength"); // 100% intensity, 34kg
    expect(classifyZoneLoaded(10, 24, refs)).toBe("power-endurance"); // ~70% intensity, 24kg
  });
});

const rec = (recordedAt: string, durationMs: number) => ({ recordedAt, durationMs });
const NOW = new Date("2026-07-21T12:00:00Z");

describe("zoneTrainingSets (SL-100, #182)", () => {
  it("sums hold duration per zone, normalised by that zone's protocol set length", () => {
    const sets = zoneTrainingSets(
      [
        rec("2026-07-20T10:00:00Z", 5000), // power, 5s
        rec("2026-07-20T10:05:00Z", 5200), // power, 5.2s, same day
        rec("2026-07-19T10:00:00Z", 5000), // power, 5s, different day → 15.2s total
        rec("2026-07-18T10:00:00Z", 30000), // endurance, 30s
      ],
      NOW,
    );
    // power set = 6 reps × 5s = 30s; endurance set = 8 reps × 30s = 240s.
    expect(sets.power).toBeCloseTo(15.2 / 30, 5);
    expect(sets.endurance).toBeCloseTo(30 / 240, 5);
    expect(sets.strength).toBe(0);
  });

  it("gives partial credit for a short warm-up instead of requiring a full session (#182)", () => {
    const sets = zoneTrainingSets(
      [rec("2026-07-20T10:00:00Z", 5000), rec("2026-07-20T10:01:00Z", 5000)],
      NOW,
    );
    expect(sets.power).toBeGreaterThan(0);
    expect(sets.power).toBeLessThan(1);
  });

  it("ignores holds older than the window", () => {
    const sets = zoneTrainingSets([rec("2026-05-01T10:00:00Z", 5000)], NOW, 28);
    expect(sets.power).toBe(0);
  });
});

describe("zoneSets (#214)", () => {
  it("sums/normalises per zone with no window filtering — an ancient recordedAt still counts", () => {
    const sets = zoneSets([
      { durationMs: 5000 }, // power, 5s
      { durationMs: 5200 }, // power, 5.2s
      { durationMs: 30000 }, // endurance, 30s
    ]);
    // power set = 6 reps × 5s = 30s; endurance set = 8 reps × 30s = 240s.
    expect(sets.power).toBeCloseTo(10.2 / 30, 5);
    expect(sets.endurance).toBeCloseTo(30 / 240, 5);
    expect(sets.strength).toBe(0);
    expect(sets["power-endurance"]).toBe(0);
  });

  it("ignores sub-1s blips and returns all-zeros for an empty array", () => {
    expect(zoneSets([])).toEqual({
      power: 0,
      strength: 0,
      "power-endurance": 0,
      endurance: 0,
    });
    expect(zoneSets([{ durationMs: 500 }])).toEqual({
      power: 0,
      strength: 0,
      "power-endurance": 0,
      endurance: 0,
    });
  });

  it("matches zoneTrainingSets when nothing falls outside the window (no time-window behavior lost)", () => {
    const recs = [
      rec("2026-07-20T10:00:00Z", 5000),
      rec("2026-07-19T10:00:00Z", 30000),
    ];
    expect(zoneTrainingSets(recs, NOW)).toEqual(zoneSets(recs));
  });
});

describe("dominantZone (#214)", () => {
  it("returns the highest-count zone — the issue's own numbers (Power 4 / Endurance 0.8) yield power", () => {
    expect(
      dominantZone({ power: 4, strength: 0, "power-endurance": 0, endurance: 0.8 }),
    ).toBe("power");
  });

  it("returns null when all zero", () => {
    expect(
      dominantZone({ power: 0, strength: 0, "power-endurance": 0, endurance: 0 }),
    ).toBeNull();
  });

  it("breaks ties deterministically by ZONE_ORDER (power, strength, power-endurance, endurance)", () => {
    expect(
      dominantZone({ power: 2, strength: 2, "power-endurance": 0, endurance: 0 }),
    ).toBe("power");
    expect(
      dominantZone({ power: 0, strength: 2, "power-endurance": 2, endurance: 0 }),
    ).toBe("strength");
    expect(
      dominantZone({ power: 0, strength: 0, "power-endurance": 2, endurance: 2 }),
    ).toBe("power-endurance");
  });
});

const model = (cf: number | null, maxF: number): ForceCurveModel => ({
  points: [{ windowS: 5, kg: maxF }],
  maxF,
  cf,
  wPrime: cf === null ? null : 500,
});

describe("recommendZone (SL-100, #182)", () => {
  it("returns null with no training at all", () => {
    expect(
      recommendZone({ power: 0, strength: 0, "power-endurance": 0, endurance: 0 }, null),
    ).toBeNull();
  });

  it("picks the least-trained zone", () => {
    const r = recommendZone(
      { power: 3, strength: 2, "power-endurance": 1, endurance: 0 },
      null,
    );
    expect(r?.zone).toBe("endurance");
    expect(r?.reason).toContain("0 endurance sets");
  });

  it("with no bias, picks the true minimum among banded candidates, not the first in ZONE_ORDER", () => {
    // All four zones sit within the 0.5-set tie band of each other, so all
    // are candidates — but with no curve model to bias the pick, the result
    // must be the actual minimum (strength, 1.0), not `power` merely because
    // it's first in ZONE_ORDER.
    const r = recommendZone(
      { power: 1.2, strength: 1.0, "power-endurance": 1.4, endurance: 1.4 },
      null,
    );
    expect(r?.zone).toBe("strength");
    expect(r?.reason).toContain("1 strength set");
  });

  it("bias can pick a within-band zone that isn't the strict minimum", () => {
    // strength (1.0) is the true minimum; power-endurance (1.3) is within
    // the 0.5-set band and on the bias side, so a low CF ratio should still
    // steer the pick to power-endurance over the untied power/endurance.
    const r = recommendZone(
      { power: 3, strength: 1.0, "power-endurance": 1.3, endurance: 3 },
      model(20, 60), // CF 20 of 60 peak → 33% (<35%) → endurance side
    );
    expect(r?.zone).toBe("power-endurance");
  });

  it("breaks ties toward the endurance side when CF is a low fraction of peak", () => {
    // power & endurance tied at 0; CF 20 of 60 peak → 33% (<35%) → endurance
    const r = recommendZone(
      { power: 0, strength: 2, "power-endurance": 2, endurance: 0 },
      model(20, 60),
    );
    expect(r?.zone).toBe("endurance");
    expect(r?.reason).toContain("CF is 33% of peak");
  });

  it("breaks ties toward the strength side when CF is a high fraction of peak", () => {
    // power & endurance tied at 0; CF 45 of 60 → 75% (>35%) → power
    const r = recommendZone(
      { power: 0, strength: 2, "power-endurance": 2, endurance: 0 },
      model(45, 60),
    );
    expect(r?.zone).toBe("power");
  });
});

describe("recommendZone picks the least-trained zone on the biased side", () => {
  it("prefers the lower of two in-band biased zones, not the first in ZONE_ORDER", () => {
    // power-endurance (0.8) is the true minimum, so an unbiased pick returns it.
    // power (1.2) and strength (0.9) are both within the 0.5 band AND both on
    // the strength side, so the bias must choose between them — and it must
    // choose strength, the lower. Picking `tied.find(...)` would return power
    // because ZONE_ORDER lists it first. Asserting "strength" therefore fails
    // for the unbiased pick ("power-endurance") and for the find-based pick
    // ("power") alike.
    const r = recommendZone(
      { power: 1.2, strength: 0.9, "power-endurance": 0.8, endurance: 5 },
      model(45, 60), // CF 45 of 60 → 75% (>35%) → strength side
    );
    expect(r?.zone).toBe("strength");
  });
});
