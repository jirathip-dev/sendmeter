import { describe, expect, it } from "vitest";
import {
  computeSendScore,
  dayRank,
  fakeSendConditionsForHour,
  humidityFrictionScore,
  percentileLabel,
  sameHourScores,
  tempFrictionScore,
} from "./weather";

describe("friction scorers (SL-69)", () => {
  it("temperature peaks at 6°C and falls ~6/°C", () => {
    expect(tempFrictionScore(6)).toBe(100);
    expect(tempFrictionScore(16)).toBe(40); // 10° away → -60
    expect(tempFrictionScore(30)).toBe(0); // clamped
  });
  it("humidity: drier is better", () => {
    expect(humidityFrictionScore(0)).toBe(100);
    expect(humidityFrictionScore(100)).toBe(0);
  });
  it("blends 60% temp / 40% humidity", () => {
    // temp 6°C → 100, humidity 50% → 45 → 0.6*100 + 0.4*45 = 78
    expect(computeSendScore(6, 50)).toBe(78);
  });
});

describe("sameHourScores (issue #99)", () => {
  it("extracts every day's score at the given hour-of-day, in chronological order", () => {
    // 3 days × 24h, aligned scores[i] = day*100 + hourOfDay.
    const scores = Array.from({ length: 72 }, (_, i) => (Math.floor(i / 24) * 100) + (i % 24));
    expect(sameHourScores(scores, 5)).toEqual([5, 105, 205]);
    expect(sameHourScores(scores, 0)).toEqual([0, 100, 200]);
  });

  it("drops null hours but keeps index alignment for the rest", () => {
    const scores: (number | null)[] = Array.from({ length: 48 }, (_, i) => i);
    scores[5] = null; // day 0, hour 5
    expect(sameHourScores(scores, 5)).toEqual([29]); // day 1, hour 5 only
  });

  it("returns an empty array when the hour never occurs", () => {
    expect(sameHourScores([1, 2, 3], 5)).toEqual([]);
  });
});

describe("dayRank (issue #99)", () => {
  const days = (n: number, v: number) => Array.from({ length: n }, () => v);

  it("is null under 20 days — too sparse to claim a rank", () => {
    expect(dayRank(50, [])).toBeNull();
    expect(dayRank(50, days(19, 40))).toBeNull();
  });

  it("counts days scoring strictly below current, and totals all of them", () => {
    // 20 days: 12 below current, 8 at/above → 60th percentile.
    const history = [...days(12, 30), ...days(8, 80)];
    const rank = dayRank(50, history);
    expect(rank).toEqual({ below: 12, total: 20, percentile: 60 });
  });

  it("rounds the percentile", () => {
    // 1 of 30 below → 3.33% → rounds to 3.
    const history = [...days(1, 10), ...days(29, 90)];
    expect(dayRank(50, history)?.percentile).toBe(3);
  });

  it("a day beating every prior day ranks at 100", () => {
    expect(dayRank(20, days(25, 10))?.percentile).toBe(100);
  });

  it("the worst possible day ranks at 0", () => {
    expect(dayRank(5, days(25, 10))?.percentile).toBe(0);
  });
});

describe("percentileLabel (issue #99)", () => {
  it("Fair below the Good threshold, Poor below Fair", () => {
    expect(percentileLabel(39)).toBe("Poor");
    expect(percentileLabel(40)).toBe("Fair");
    expect(percentileLabel(74)).toBe("Fair");
  });
  it("Good at/above 75, Prime at/above 90", () => {
    expect(percentileLabel(75)).toBe("Good");
    expect(percentileLabel(89)).toBe("Good");
    expect(percentileLabel(90)).toBe("Prime");
  });
});

describe("?fake-weather fixtures hold their intended percentile band at every hour (issue #99)", () => {
  // A reviewer previously caught `prime` dipping to percentile 0 at one
  // specific hour-of-day — the diurnal cycle passed exactly through the
  // scorer's own optimum there and beat the fixed current reading on every
  // one of the 30 days. Sweep all 24 hours so a regression like that fails
  // here instead of only showing up interactively at a particular time of day.
  const hours = Array.from({ length: 24 }, (_, h) => h);

  it("hot: current 35°C/45% ranks in the top decile (>=90) at every hour", () => {
    for (const h of hours) {
      const cond = fakeSendConditionsForHour("hot", h);
      expect(cond.percentile).not.toBeNull();
      expect(cond.percentile as number).toBeGreaterThanOrEqual(90);
    }
  });

  it("prime: current 5°C/30% ranks >=75 at every hour", () => {
    for (const h of hours) {
      const cond = fakeSendConditionsForHour("prime", h);
      expect(cond.percentile).not.toBeNull();
      expect(cond.percentile as number).toBeGreaterThanOrEqual(75);
    }
  });

  it("bad: current 36°C/95% against the hot history ranks below Fair (<40) at every hour", () => {
    for (const h of hours) {
      const cond = fakeSendConditionsForHour("bad", h);
      expect(cond.percentile).not.toBeNull();
      expect(cond.percentile as number).toBeLessThan(40);
    }
  });

  it("no-hist: percentile/daysBelow/daysTotal are all null regardless of hour", () => {
    const cond = fakeSendConditionsForHour("no-hist", 12);
    expect(cond.percentile).toBeNull();
    expect(cond.daysBelow).toBeNull();
    expect(cond.daysTotal).toBeNull();
    expect(cond.hist).toBeNull();
  });
});
