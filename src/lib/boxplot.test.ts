import { describe, expect, it } from "vitest";
import { boxStats, fiveNumberSummary } from "./boxplot";

describe("fiveNumberSummary (issue #100)", () => {
  it("is null for empty input", () => {
    expect(fiveNumberSummary([])).toBeNull();
  });

  it("collapses to the value itself for a single reading", () => {
    expect(fiveNumberSummary([5])).toEqual({
      min: 5,
      q1: 5,
      median: 5,
      q3: 5,
      max: 5,
    });
  });

  it("interpolates quartiles for two values", () => {
    expect(fiveNumberSummary([1, 3])).toEqual({
      min: 1,
      q1: 1.5,
      median: 2,
      q3: 2.5,
      max: 3,
    });
  });

  it("interpolates quartiles for an odd count (R-7 method)", () => {
    expect(fiveNumberSummary([1, 2, 3, 4, 5])).toEqual({
      min: 1,
      q1: 2,
      median: 3,
      q3: 4,
      max: 5,
    });
  });

  it("interpolates quartiles for an even count (R-7 method)", () => {
    expect(fiveNumberSummary([1, 2, 3, 4])).toEqual({
      min: 1,
      q1: 1.75,
      median: 2.5,
      q3: 3.25,
      max: 4,
    });
  });

  it("sorts unsorted input before computing", () => {
    expect(fiveNumberSummary([5, 1, 4, 2, 3])).toEqual({
      min: 1,
      q1: 2,
      median: 3,
      q3: 4,
      max: 5,
    });
  });
});

describe("boxStats (issue #100)", () => {
  it("is null for empty input", () => {
    expect(boxStats([])).toBeNull();
  });

  it("collapses to the single value for n=1, no outliers", () => {
    expect(boxStats([5])).toEqual({
      q1: 5,
      median: 5,
      q3: 5,
      whiskerLo: 5,
      whiskerHi: 5,
      outliers: [],
    });
  });

  it("small n (3) with no outliers: whiskers = min/max", () => {
    // q1=1.5, median=2, q3=2.5 → iqr=1 → fences [0, 4], all 3 values inside.
    expect(boxStats([1, 2, 3])).toEqual({
      q1: 1.5,
      median: 2,
      q3: 2.5,
      whiskerLo: 1,
      whiskerHi: 3,
      outliers: [],
    });
  });

  it("no-outlier case: whiskers equal min/max", () => {
    // q1=2, median=3, q3=4 → iqr=2 → fences [-1, 7], 1..5 all inside.
    const stats = boxStats([1, 2, 3, 4, 5]);
    expect(stats).toEqual({
      q1: 2,
      median: 3,
      q3: 4,
      whiskerLo: 1,
      whiskerHi: 5,
      outliers: [],
    });
  });

  it("flags outliers on both sides and clamps whiskers to the furthest in-fence point", () => {
    // sorted: [-100, 10, 11, 12, 13, 14, 100], n=7
    // q1=10.5, median=12, q3=13.5 → iqr=3 → fences [6, 18]
    // -100 and 100 sit outside the fence → outliers; whiskers clamp to 10/14.
    const stats = boxStats([-100, 100, 12, 10, 14, 11, 13]);
    expect(stats).toEqual({
      q1: 10.5,
      median: 12,
      q3: 13.5,
      whiskerLo: 10,
      whiskerHi: 14,
      outliers: [-100, 100],
    });
  });
});
