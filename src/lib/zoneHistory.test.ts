import { describe, expect, it } from "vitest";
import { classifyZone, recommendZone, zoneTrainingDays } from "./zoneHistory";
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
