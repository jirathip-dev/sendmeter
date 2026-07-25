import { describe, expect, it } from "vitest";
import { dailyBoxStats, type TrendSample } from "./forceTrend";

describe("dailyBoxStats (issue #145)", () => {
  it("degenerates cleanly for a 1-rep day: whiskers = median = the value, no outliers", () => {
    const days = dailyBoxStats([{ recordedAt: "2026-07-20T10:00:00Z", val: 42 }]);
    expect(days).toHaveLength(1);
    expect(days[0]).toMatchObject({
      date: "2026-07-20",
      best: 42,
      count: 1,
    });
    expect(days[0]!.stats).toEqual({
      q1: 42,
      median: 42,
      q3: 42,
      whiskerLo: 42,
      whiskerHi: 42,
      outliers: [],
    });
  });

  it("falls back to min/max (not NaN/Infinity) for a zero-IQR day of identical values", () => {
    const samples: TrendSample[] = [
      { recordedAt: "2026-07-20T10:00:00Z", val: 30 },
      { recordedAt: "2026-07-20T10:01:00Z", val: 30 },
      { recordedAt: "2026-07-20T10:02:00Z", val: 30 },
    ];
    const [day] = dailyBoxStats(samples);
    expect(day!.stats).toEqual({
      q1: 30,
      median: 30,
      q3: 30,
      whiskerLo: 30,
      whiskerHi: 30,
      outliers: [],
    });
    expect(Number.isFinite(day!.stats.whiskerLo)).toBe(true);
    expect(Number.isFinite(day!.stats.whiskerHi)).toBe(true);
  });

  it("groups multiple days correctly, ordered ascending, tracking best + count per day", () => {
    const samples: TrendSample[] = [
      { recordedAt: "2026-07-21T09:00:00Z", val: 40 },
      { recordedAt: "2026-07-20T09:00:00Z", val: 50 },
      { recordedAt: "2026-07-20T10:00:00Z", val: 55 },
      { recordedAt: "2026-07-20T11:00:00Z", val: 45 },
      { recordedAt: "2026-07-21T10:00:00Z", val: 60 },
    ];
    const days = dailyBoxStats(samples);
    expect(days.map((d) => d.date)).toEqual(["2026-07-20", "2026-07-21"]);

    const day0 = days[0]!;
    expect(day0.count).toBe(3);
    expect(day0.best).toBe(55);
    expect(day0.stats.median).toBe(50);

    const day1 = days[1]!;
    expect(day1.count).toBe(2);
    expect(day1.best).toBe(60);
    // best rep's own timestamp is retained for x-position/PR callout
    expect(day1.t).toBe(Date.parse("2026-07-21T10:00:00Z"));
  });

  it("is unit-agnostic — works the same whether `val` is kg or %BW", () => {
    const kgSamples: TrendSample[] = [
      { recordedAt: "2026-07-20T09:00:00Z", val: 20 },
      { recordedAt: "2026-07-20T10:00:00Z", val: 24 },
    ];
    const bwSamples: TrendSample[] = [
      { recordedAt: "2026-07-20T09:00:00Z", val: 33.3 },
      { recordedAt: "2026-07-20T10:00:00Z", val: 40.0 },
    ];
    const kgDays = dailyBoxStats(kgSamples);
    const bwDays = dailyBoxStats(bwSamples);
    expect(kgDays[0]!.count).toBe(bwDays[0]!.count);
    expect(kgDays[0]!.stats.median).toBe(22);
    expect(bwDays[0]!.stats.median).toBeCloseTo(36.65, 5);
  });
});
