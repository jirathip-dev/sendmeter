import { describe, expect, it } from "vitest";
import {
  dailyBoxStats,
  hitWidthsPx,
  neighborGapsPx,
  trendChartRecordings,
  type TrendSample,
} from "./forceTrend";
import type { TindeqRecordingMeta } from "../types";

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

describe("neighborGapsPx", () => {
  it("uses the smaller of the two adjacent gaps for an interior point", () => {
    expect(neighborGapsPx([0, 10, 13, 30])).toEqual([10, 3, 3, 17]);
  });

  it("gives a lone point Infinity (no neighbor)", () => {
    expect(neighborGapsPx([42])).toEqual([Infinity]);
  });

  it("gives an empty array for no points", () => {
    expect(neighborGapsPx([])).toEqual([]);
  });
});

describe("hitWidthsPx (issue #145 revision: hit target must be per-day, not dataset-wide)", () => {
  it("stays wide for every OTHER day when just one pair of days sits close together", () => {
    // Regression for the Tester-caught bug: `days` widely spaced except one
    // near-duplicate pair near the end (e.g. two training days' representative
    // timestamps a couple seconds apart across a midnight boundary). A hit
    // width derived from the dataset-wide minimum gap collapsed to near-zero
    // for EVERY day, not just the close pair — this asserts the far-apart
    // days keep a full, usable hit width regardless.
    const xs = [0, 50, 100, 150, 200.5, 201]; // last two are 0.5px apart
    const widths = hitWidthsPx(xs, 8, 4);
    // Interior/far days: nearest gap is 50px, hit width caps at max(boxW,12)=12
    expect(widths[0]).toBe(12);
    expect(widths[1]).toBe(12);
    expect(widths[2]).toBe(12);
    expect(widths[3]).toBe(12);
    // The close pair still gets a *usable* (floored) width, not ~0
    expect(widths[4]).toBeCloseTo(4, 5);
    expect(widths[5]).toBeCloseTo(4, 5);
    for (const w of widths) expect(w).toBeGreaterThanOrEqual(4);
  });

  it("never drops below minW even for a zero-gap duplicate pair", () => {
    const widths = hitWidthsPx([0, 100, 100, 200], 8, 4);
    for (const w of widths) expect(w).toBeGreaterThanOrEqual(4);
  });

  it("falls back to boxW for a single point with no neighbor", () => {
    expect(hitWidthsPx([10], 8, 4)).toEqual([8]);
  });

  it("caps at max(boxW, 12) so a wide-open gap doesn't blow up the hit target", () => {
    expect(hitWidthsPx([0, 1000], 8, 4)).toEqual([12, 12]);
  });
});

describe("trendChartRecordings excludes Prehab (#325)", () => {
  function rec(
    recordedAt: string,
    peakKg: number,
    over: Partial<TindeqRecordingMeta> = {},
  ): TindeqRecordingMeta {
    return {
      id: `r-${recordedAt}`,
      recordedAt,
      durationMs: 10_000,
      peakKg,
      avgKg: peakKg * 0.9,
      sampleCount: 100,
      note: "",
      tag: "FDP",
      side: "left",
      groupId: null,
      protocolRunId: null,
      setNo: null,
      zone: null,
      ...over,
    };
  }

  it("drops a Prehab hold even when it's the most recent recording", () => {
    // The invariant `ForceTrendChart`'s own "Last day"/"vs 30d avg" figures
    // rely on: "a submax endurance day no longer drags 'Last' around" — a
    // daily sub-CF Prehab hold is the same failure mode, so it must never
    // become `lastDay` and fabricate a fake capacity drop.
    const recordings = [
      rec("2026-07-01T10:00:00Z", 40, { zone: "strength" }),
      rec("2026-07-10T10:00:00Z", 42, { zone: "strength" }),
      rec("2026-07-20T10:00:00Z", 15, { zone: "prehab" }),
    ];
    const filtered = trendChartRecordings(recordings, null, null);
    expect(filtered.map((r) => r.id)).toEqual([recordings[0]!.id, recordings[1]!.id]);
  });

  it("still respects the tag/side scoping alongside the effort filter", () => {
    const recordings = [
      rec("2026-07-01T10:00:00Z", 40, { tag: "FDP", side: "left" }),
      rec("2026-07-02T10:00:00Z", 40, { tag: "FDP", side: "right" }),
      rec("2026-07-03T10:00:00Z", 40, { tag: "Other", side: "left" }),
    ];
    const filtered = trendChartRecordings(recordings, "FDP", "left");
    expect(filtered.map((r) => r.id)).toEqual([recordings[0]!.id]);
  });
});
