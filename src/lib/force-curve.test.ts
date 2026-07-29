import { describe, it, expect } from "vitest";
import {
  meanMaxForce,
  pickCurveRecordings,
  computeForceCurve,
  predictForce,
  zoneTarget,
  zonePrescription,
  adjustedEndurance,
  ZONE_PROTOCOLS,
  ZONE_INTENSITY,
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

describe("computeForceCurve — multi-point fit (SL-80b)", () => {
  it("regresses over the top efforts per window, not just the envelope", () => {
    // Two flat 60s holds: a 20kg best and a 10kg repeat. Envelope-only fit
    // (depth 1) sees only 20kg → CF 20; depth 2 averages both → CF 15.
    const recs = [hold(60, 20), hold(60, 10)];
    const deep = computeForceCurve(recs, { fitDepth: 2 })!;
    expect(deep.cf).toBeCloseTo(15, 1);
    const envelope = computeForceCurve(recs, { fitDepth: 1 })!;
    expect(envelope.cf).toBeCloseTo(20, 1);
    // the chart's envelope points are unchanged by the fit depth
    expect(deep.points).toEqual(envelope.points);
  });

  it("still needs three distinct long windows for a CF", () => {
    // 12s holds only reach the 10s window — one distinct fit window even
    // with many recordings → no CF.
    const m = computeForceCurve([hold(12, 20), hold(12, 18), hold(12, 16)])!;
    expect(m.cf).toBeNull();
  });
});

describe("zoneTarget / zonePrescription — adjustable intensity (SL-97)", () => {
  const model: ForceCurveModel = { points: [], maxF: 40, cf: 20, wPrime: 300 };
  const noCf: ForceCurveModel = { points: [], maxF: 40, cf: null, wPrime: null };

  it("100% is an exact no-op — same numbers as the un-adjusted zoneTarget for every zone", () => {
    for (const q of ["power", "strength", "power-endurance", "endurance"] as const) {
      const base = zoneTarget(model, q);
      const adjusted = zoneTarget(model, q, 100);
      expect(adjusted).toEqual(base);
      expect(adjusted!.workS).toBe(ZONE_PROTOCOLS[q].holdS);
      expect(adjusted!.basis).not.toContain("intensity");
    }
  });

  it("kg scales linearly with pct", () => {
    const base = zoneTarget(model, "power")!;
    const at80 = zoneTarget(model, "power", 80)!;
    expect(at80.targetKg).toBeCloseTo(base.targetKg * 0.8, 1);
    expect(at80.lowKg).toBeCloseTo(base.lowKg * 0.8, 1);
    expect(at80.highKg).toBeCloseTo(base.highKg * 0.8, 1);
    expect(at80.basis).toContain("intensity 80%");
  });

  it("strength hold at reduced intensity matches the W′-cost invariant (hand-built model)", () => {
    // targetKg(100%) = 34, cf = 10 → base W′ cost = (34 − 10) × 10s = 240 kg·s.
    const m: ForceCurveModel = { points: [], maxF: 40, cf: 10, wPrime: 200 };
    const t68 = zoneTarget(m, "strength", 68)!;
    expect(t68.targetKg).toBeCloseTo(23.1, 1); // 34 × 0.68
    expect(t68.workS).toBe(18); // (34−10)×10 / (23.1−10) ≈ 18.3 → round to 18
    // the recovered W′ cost stays close to the 100% baseline (240) despite rounding
    expect((t68.targetKg - 10) * t68.workS).toBeGreaterThan(220);
    expect((t68.targetKg - 10) * t68.workS).toBeLessThan(260);
  });

  it("clamps the hold at the zone's max when the scaled target drops to/below CF", () => {
    const m: ForceCurveModel = { points: [], maxF: 40, cf: 30, wPrime: 100 };
    expect(zoneTarget(m, "strength", 60)!.workS).toBe(30); // strength max clamp
    expect(zoneTarget(m, "power", 60)!.workS).toBe(15); // power max clamp
  });

  it("falls back to the impulse-preserving formula when there's no CF fit", () => {
    const t70 = zoneTarget(noCf, "strength", 70)!;
    expect(t70.targetKg).toBeCloseTo(23.8, 1); // 34 × 0.7
    expect(t70.workS).toBe(14); // 10 × 34 / 23.8 ≈ 14.29 → round to 14
    // power/strength still exist without a CF fit
    expect(zoneTarget(noCf, "power", 70)).not.toBeNull();
  });

  it("endurance keeps total time-under-tension ~constant and sets shrinks to compensate (#320: reps stays 1)", () => {
    const t60 = zonePrescription(model, "endurance", 60)!;
    expect(t60.holdS).toBe(85); // 30 × (100/60)² ≈ 83.3 → round to nearest 5
    expect(t60.reps).toBe(1);
    expect(t60.sets).toBe(3); // round(8 × 30 / 85) = 3
    // base time-under-tension was 30 × 8 = 240s; rounding keeps it in the ballpark
    expect(t60.holdS * t60.sets).toBeGreaterThan(200);
    expect(t60.holdS * t60.sets).toBeLessThan(280);
    expect(t60.sets).toBeLessThanOrEqual(ZONE_PROTOCOLS.endurance.sets);
  });

  it("zonePrescription(endurance, 100) returns the flipped 1×8 shape (#320)", () => {
    const t100 = zonePrescription(model, "endurance", 100)!;
    expect(t100.holdS).toBe(30);
    expect(t100.reps).toBe(1);
    expect(t100.sets).toBe(8);
    expect(t100.restRepsS).toBe(0);
    expect(t100.restSetsS).toBe(30);
  });

  it("adjustedEndurance clamps hold to [20, 240]s", () => {
    expect(adjustedEndurance(30, 8, 110).holdS).toBeGreaterThanOrEqual(20);
    // an extreme drop (well beyond the UI's 60% floor) hits the 240s cap
    expect(adjustedEndurance(30, 8, 5).holdS).toBe(240);
    expect(adjustedEndurance(30, 8, 5).sets).toBe(1);
  });

  it("clamps input pct to [60, 110]", () => {
    expect(zoneTarget(model, "power", 200)).toEqual(zoneTarget(model, "power", ZONE_INTENSITY.max));
    expect(zoneTarget(model, "power", -50)).toEqual(zoneTarget(model, "power", ZONE_INTENSITY.min));
  });

  it("zonePrescription returns null when the zone itself is undefined for the model", () => {
    expect(zonePrescription(noCf, "endurance", 80)).toBeNull();
    expect(zonePrescription(noCf, "power-endurance", 80)).toBeNull();
  });

  describe("pct > 100 shortens the hold for every above-CF zone (#105/SL-103)", () => {
    // Same W′-cost-constant math as the <100% path, just scaling kg up
    // instead of down: raising the load means less time is needed to bank
    // the same (F − CF) × t dose, so the hold SHRINKS.
    it("power: 110% shortens the 5s base hold", () => {
      // baseKg 38 (0.95×40), newKg 41.8 (×1.1) → (18×5)/21.8 ≈ 4.13s → round to 4
      expect(zoneTarget(model, "power", 110)!.workS).toBe(4);
      expect(zoneTarget(model, "power", 110)!.workS).toBeLessThan(ZONE_PROTOCOLS.power.holdS);
    });

    it("strength: 110% shortens the 10s base hold", () => {
      // baseKg 34 (0.85×40), newKg 37.4 → (14×10)/17.4 ≈ 8.05s → round to 8
      expect(zoneTarget(model, "strength", 110)!.workS).toBe(8);
      expect(zoneTarget(model, "strength", 110)!.workS).toBeLessThan(ZONE_PROTOCOLS.strength.holdS);
    });

    it("power-endurance: 110% shortens the 7s base hold", () => {
      // f60 25, newKg 27.5 → (5×7)/7.5 ≈ 4.67s → round to 5
      expect(zoneTarget(model, "power-endurance", 110)!.workS).toBe(5);
      expect(zoneTarget(model, "power-endurance", 110)!.workS).toBeLessThan(
        ZONE_PROTOCOLS["power-endurance"].holdS,
      );
    });

    it("power: the 3s floor engages when the W′-cost math would go lower", () => {
      // baseKg sits just 0.1kg above CF, so scaling up to 110% collapses the
      // denominator (newKg − cf) far faster than the numerator shrinks —
      // the raw math wants a sub-1s hold, which the zone's [3, 15]s clamp floors.
      const tightPower: ForceCurveModel = { points: [], maxF: 40, cf: 37.9, wPrime: 300 };
      expect(zoneTarget(tightPower, "power", 110)!.workS).toBe(3);
    });

    it("strength: the 5s floor engages under the same tight-margin setup", () => {
      const tightStrength: ForceCurveModel = { points: [], maxF: 100, cf: 84.9, wPrime: 300 };
      expect(zoneTarget(tightStrength, "strength", 110)!.workS).toBe(5);
    });

    it("power-endurance: the 5s floor engages under the same tight-margin setup", () => {
      // cf 25, wPrime 6 → f60 = 25 + 6/60 = 25.1, just above cf.
      const tightPe: ForceCurveModel = { points: [], maxF: 40, cf: 25, wPrime: 6 };
      expect(zoneTarget(tightPe, "power-endurance", 110)!.workS).toBe(5);
    });
  });
});
