import { describe, expect, it } from "vitest";
import { classifyZone, classifyZoneLoaded, recommendZone, zoneTrainingDays } from "./zoneHistory";
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

describe("zoneTrainingDays (SL-100)", () => {
  it("counts distinct days per zone within the window", () => {
    const days = zoneTrainingDays(
      [
        rec("2026-07-20T10:00:00Z", 5000), // power, day A
        rec("2026-07-20T10:05:00Z", 5200), // power, same day A → still 1
        rec("2026-07-19T10:00:00Z", 5000), // power, day B → 2
        rec("2026-07-18T10:00:00Z", 30000), // endurance
      ],
      NOW,
    );
    expect(days.power).toBe(2);
    expect(days.endurance).toBe(1);
    expect(days.strength).toBe(0);
  });

  it("ignores holds older than the window", () => {
    const days = zoneTrainingDays([rec("2026-05-01T10:00:00Z", 5000)], NOW, 28);
    expect(days.power).toBe(0);
  });
});

const model = (cf: number | null, maxF: number): ForceCurveModel => ({
  points: [{ windowS: 5, kg: maxF }],
  maxF,
  cf,
  wPrime: cf === null ? null : 500,
});

describe("recommendZone (SL-100)", () => {
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
    expect(r?.reason).toContain("0 endurance days");
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
