import { describe, expect, it } from "vitest";
import { activityMix } from "./trainingLoad";

const session = (date: string, type: string, load: number, typeLabel = "") => ({
  date, type, load, typeLabel,
});

describe("activityMix", () => {
  it("includes both ends of the 28-day calendar window", () => {
    const result = activityMix([
      session("2026-07-06", "board", 100),
      session("2026-07-05", "gym", 999),
      session("2026-08-02", "gym", 200),
      session("2026-08-03", "gym", 999),
    ], "2026-08-02");
    expect(result.total).toBe(300);
  });

  it("groups activities, sorts by AU, and calculates percentages", () => {
    const result = activityMix([
      session("2026-08-01", "board", 100),
      session("2026-08-02", "board", 200),
      session("2026-08-02", "gym", 100),
    ], "2026-08-02");
    expect(result.activities.map(({ type, load, percentage }) => ({ type, load, percentage }))).toEqual([
      { type: "board", load: 300, percentage: 75 },
      { type: "gym", load: 100, percentage: 25 },
    ]);
  });

  it("returns an empty mix, without NaN percentages, for zero load", () => {
    const result = activityMix([session("2026-08-02", "board", 0)], "2026-08-02");
    expect(result).toEqual({ total: 0, activities: [] });
  });

  it("keeps unknown and legacy activity types with a useful label", () => {
    const result = activityMix([
      session("2026-08-02", "moon_board", 80, "Moon Board Legacy"),
      session("2026-08-02", "mystery-type", 20),
    ], "2026-08-02");
    expect(result.activities.map((item) => item.label)).toEqual([
      "Moon Board Legacy",
      "Mystery Type",
    ]);
  });
});
