import { describe, expect, it } from "vitest";
import {
  predictSessionRpe,
  repDepletion,
  RPE_DEPLETION,
  rpeForDepletion,
  sessionDepletion,
  type DepletionRep,
} from "./rpeDepletion";

// KEEP-IN-SYNC: the same vectors run in
// `SendLogWatchCore/Tests/SendLogWatchCoreTests/RPEDepletionTests.swift`.
// Both implementations must agree to 0.1 RPE on every case below — that's the
// whole point of duplicating the math instead of porting the curve fit.

/// The load→RPE table from issue #280.
const MAPPING_VECTORS: [load: number, rpe: number][] = [
  [0, 1],
  [0.5, 2.6],
  [1, 4],
  [2, 6],
  [4, 8.2],
  [6, 9.2],
  [8, 9.6],
];

const rep = (
  peakKg: number,
  durationS: number,
  cf: number | null,
  wPrime: number | null,
): DepletionRep => ({ peakKg, durationS, cf, wPrime });

describe("repDepletion", () => {
  it("is exactly 1.0 for a rep taken to failure ON the curve", () => {
    // P = CF + W'/T is the definition of the curve, so (P - CF)·T = W'.
    // This identity is the vector that catches sign and unit errors in both
    // implementations at once.
    const cf = 30;
    const wPrime = 180;
    const t = 10;
    expect(repDepletion(rep(cf + wPrime / t, t, cf, wPrime))).toBeCloseTo(1, 10);
  });

  it("scales linearly in force above CF and in duration", () => {
    expect(repDepletion(rep(39, 10, 30, 180))).toBeCloseTo(0.5, 10);
    expect(repDepletion(rep(48, 5, 30, 180))).toBeCloseTo(0.5, 10);
  });

  it("contributes nothing at or below CF (the known limitation)", () => {
    expect(repDepletion(rep(30, 60, 30, 180))).toBe(0);
    expect(repDepletion(rep(25, 60, 30, 180))).toBe(0);
  });

  it("is null without a usable curve", () => {
    expect(repDepletion(rep(48, 10, null, null))).toBeNull();
    expect(repDepletion(rep(48, 10, 30, null))).toBeNull();
    expect(repDepletion(rep(48, 10, null, 180))).toBeNull();
    // Degenerate fit — nothing to divide by.
    expect(repDepletion(rep(48, 10, 30, 0))).toBeNull();
  });

  it("treats a negative duration as zero rather than negative depletion", () => {
    expect(repDepletion(rep(48, -5, 30, 180))).toBe(0);
  });
});

describe("sessionDepletion", () => {
  it("sums each rep against ITS OWN tag's curve", () => {
    const load = sessionDepletion([
      rep(48, 10, 30, 180), // 1.0
      rep(30, 5, 20, 100), // 0.5
    ]);
    expect(load).toBeCloseTo(1.5, 10);
  });

  it("skips reps whose tag has no curve, keeping the ones that do", () => {
    const load = sessionDepletion([
      rep(48, 10, 30, 180), // 1.0
      rep(60, 30, null, null), // no curve — contributes nothing
    ]);
    expect(load).toBeCloseTo(1, 10);
  });

  it("is null (not 0) when NO rep had a curve", () => {
    expect(sessionDepletion([rep(48, 10, null, null)])).toBeNull();
    expect(sessionDepletion([])).toBeNull();
  });
});

describe("rpeForDepletion", () => {
  it("matches the published table, rounded to 0.1", () => {
    for (const [load, expected] of MAPPING_VECTORS) {
      expect(rpeForDepletion(load)).toBe(expected);
    }
  });

  it("stays inside [1, 10] however deep the hole", () => {
    expect(rpeForDepletion(1000)).toBe(10);
    expect(rpeForDepletion(0)).toBe(1);
    expect(rpeForDepletion(-5)).toBe(1);
  });
});

describe("predictSessionRpe", () => {
  it("predicts 4.0 for a single on-curve rep to failure", () => {
    const p = predictSessionRpe([rep(48, 10, 30, 180)]);
    expect(p.load).toBeCloseTo(1, 10);
    expect(p.rpe).toBe(4);
    expect(p.fromCurve).toBe(true);
  });

  it("predicts a mixed-tag session from both curves", () => {
    const p = predictSessionRpe([rep(48, 10, 30, 180), rep(30, 5, 20, 100)]);
    expect(p.rpe).toBe(5.1); // L = 1.5
    expect(p.fromCurve).toBe(true);
  });

  it("falls back — never throws, never blocks the save — with no curve", () => {
    const p = predictSessionRpe([rep(48, 10, null, null), rep(60, 30, 0, 0)]);
    expect(p.rpe).toBe(RPE_DEPLETION.fallbackRpe);
    expect(p.fromCurve).toBe(false);
    expect(p.load).toBeNull();
  });

  it("falls back on an empty session rather than reporting RPE 1", () => {
    expect(predictSessionRpe([])).toEqual({
      rpe: RPE_DEPLETION.fallbackRpe,
      fromCurve: false,
      load: null,
    });
  });
});
