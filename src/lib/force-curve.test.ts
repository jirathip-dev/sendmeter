import { describe, it, expect } from "vitest";
import {
  meanMaxForce,
  pickCurveRecordings,
  computeForceCurve,
  predictForce,
  zoneTarget,
  type ForceCurveModel,
} from "./force-curve";
import type { TindeqSample } from "../types";

/// A constant-force hold sampled at 10 Hz (t in ms).
function hold(seconds: number, kg: number): TindeqSample[] {
  const arr: TindeqSample[] = [];
  for (let ms = 0; ms <= seconds * 1000; ms += 100) arr.push({ t: ms, kg });
  return arr;
}

/// A linearly-decaying hold from `startKg` down over `seconds` at `slope` kg/s.
function decay(seconds: number, startKg: number, slope: number): TindeqSample[] {
  const arr: TindeqSample[] = [];
  for (let ms = 0; ms <= seconds * 1000; ms += 100) {
    arr.push({ t: ms, kg: startKg - slope * (ms / 1000) });
  }
  return arr;
}

describe("meanMaxForce", () => {
  it("equals the constant force for any window that fits", () => {
    expect(meanMaxForce(hold(12, 30), 10)).toBeCloseTo(30, 5);
    expect(meanMaxForce(hold(12, 30), 1)).toBeCloseTo(30, 5);
  });

  it("returns null when the window is longer than the recording", () => {
    expect(meanMaxForce(hold(12, 30), 15)).toBeNull();
  });
});

describe("computeForceCurve", () => {
  it("returns null for no data", () => {
    expect(computeForceCurve([])).toBeNull();
    expect(computeForceCurve([[]])).toBeNull();
  });

  it("a short constant hold gives maxF but no CF fit (too few long windows)", () => {
    const m = computeForceCurve([hold(12, 30)])!;
    expect(m.maxF).toBe(30);
    expect(m.points.every((p) => p.kg === 30)).toBe(true);
    expect(m.cf).toBeNull();
    expect(m.wPrime).toBeNull();
  });

  it("a long decaying hold fits a plausible critical-force model", () => {
    const m = computeForceCurve([decay(120, 40, 0.15)])!;
    expect(m.cf).not.toBeNull();
    expect(m.wPrime).not.toBeNull();
    expect(m.cf!).toBeGreaterThan(0);
    expect(m.cf!).toBeLessThan(m.maxF); // sustainable force below peak
  });

  it("aggregates the best force across multiple recordings per window", () => {
    const m = computeForceCurve([hold(6, 25), hold(6, 32)])!;
    // mean-max at each window takes the stronger recording
    expect(m.maxF).toBe(32);
  });
});

describe("predictForce", () => {
  it("falls back to maxF when there is no CF fit", () => {
    const m: ForceCurveModel = { points: [], maxF: 30, cf: null, wPrime: null };
    expect(predictForce(m, 5)).toBe(30);
  });

  it("follows CF + W'/t, clamped at maxF", () => {
    const m: ForceCurveModel = { points: [], maxF: 40, cf: 20, wPrime: 300 };
    expect(predictForce(m, 60)).toBeCloseTo(25, 5); // 20 + 300/60
    expect(predictForce(m, 1)).toBe(40); // 20 + 300 → clamped to maxF
  });
});

describe("zoneTarget", () => {
  const model: ForceCurveModel = { points: [], maxF: 40, cf: 20, wPrime: 300 };

  it("derives power/strength targets from maxF", () => {
    expect(zoneTarget(model, "power")!.targetKg).toBe(38); // 40 × 0.95
    expect(zoneTarget(model, "strength")!.targetKg).toBe(34); // 40 × 0.85
  });

  it("derives endurance/power-endurance targets from CF", () => {
    expect(zoneTarget(model, "endurance")!.targetKg).toBe(18); // cf × 0.9
    expect(zoneTarget(model, "power-endurance")!.targetKg).toBe(25); // cf + W'/60
  });

  it("returns null for CF-based zones when CF is unknown", () => {
    const noCf: ForceCurveModel = { points: [], maxF: 40, cf: null, wPrime: null };
    expect(zoneTarget(noCf, "endurance")).toBeNull();
    expect(zoneTarget(noCf, "power-endurance")).toBeNull();
    expect(zoneTarget(noCf, "power")!.targetKg).toBe(38); // maxF-based still works
  });
});

describe("pickCurveRecordings (SL-80)", () => {
  const now = Date.parse("2026-07-20T00:00:00Z");
  const daysAgo = (d: number) =>
    new Date(now - d * 86_400_000).toISOString();
  let seq = 0;
  const rec = (durationS: number, avgKg: number, ageDays: number) => ({
    id: `r${seq++}`,
    durationMs: durationS * 1000,
    avgKg,
    recordedAt: daysAgo(ageDays),
  });

  it("a flood of short reps cannot evict the long holds", () => {
    const longHolds = [rec(35, 18, 20), rec(60, 15, 25)];
    const shortFlood = Array.from({ length: 50 }, () => rec(7, 22, 0));
    const picked = pickCurveRecordings([...shortFlood, ...longHolds], now);
    const ids = picked.map((r) => r.id);
    expect(ids).toContain(longHolds[0]!.id);
    expect(ids).toContain(longHolds[1]!.id);
    // and the flood itself is capped at the per-bucket best few
    expect(picked.filter((r) => r.durationMs === 7000).length).toBeLessThanOrEqual(3);
  });

  it("takes the hardest efforts per duration bucket", () => {
    const weak = rec(7, 10, 1);
    const strong = [rec(7, 30, 1), rec(7, 28, 1), rec(7, 26, 1)];
    const picked = pickCurveRecordings([weak, ...strong], now);
    const ids = picked.map((r) => r.id);
    for (const s of strong) expect(ids).toContain(s.id);
    // weak short rep only survives via the longest-efforts guarantee, which
    // in this all-short pool it may — but the bucket picks are the strong ones
    expect(picked.filter((r) => r.avgKg >= 26).length).toBe(3);
  });

  it("ignores stale recordings when recent ones exist, but falls back for a dormant exercise", () => {
    const old = rec(30, 20, 200);
    const fresh = rec(7, 15, 1);
    const withFresh = pickCurveRecordings([old, fresh], now);
    expect(withFresh.map((r) => r.id)).toEqual([fresh.id]);
    const dormantOnly = pickCurveRecordings([old], now);
    expect(dormantOnly.map((r) => r.id)).toEqual([old.id]);
  });
});
