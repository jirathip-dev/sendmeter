import { describe, expect, it } from "vitest";
import { zoneTarget, type ForceCurveModel } from "./force-curve";
import { sampleDisplayBand, sampleDisplayCurve, qualityRegions } from "./forceCurveDisplay";
import { classifyZoneLoaded } from "./zoneHistory";
import { fitCapabilityRegression } from "./capabilityModel";
import { presetTargetKg } from "./protocol";
import type { TindeqPreset } from "../types";

const model: ForceCurveModel = {
  maxF: 40,
  cf: 20,
  wPrime: 120,
  points: [
    { windowS: 1, kg: 40 },
    { windowS: 3, kg: 37 },
    { windowS: 5, kg: 34 },
    { windowS: 7, kg: 32 },
    { windowS: 10, kg: 30 },
    { windowS: 20, kg: 27 },
    { windowS: 60, kg: 22 },
    { windowS: 120, kg: 21 },
  ],
};
model.capabilityFit = fitCapabilityRegression(model.points, model.cf)!;

describe("sampleDisplayCurve", () => {
  it("selects the deterministic Hill regression for the curved seed-like envelope", () => {
    const seedLike = model.points.map((p) => ({ ...p }));
    const a = fitCapabilityRegression(seedLike, 18.7)!;
    const b = fitCapabilityRegression(seedLike, 18.7)!;
    expect(a).toEqual(b);
    expect(a.family).toBe("hill");
  });

  it("is a regression rather than chasing every measured anchor", () => {
    const points = sampleDisplayCurve(model, 1, 120, 400);
    expect(points[0]!.durationS).toBe(1);
    expect(points.at(-1)!.durationS).toBeCloseTo(120, 10);
    expect(model.points.some((anchor) => {
      const nearest = points.reduce((a, b) => Math.abs(b.durationS - anchor.windowS) < Math.abs(a.durationS - anchor.windowS) ? b : a);
      return Math.abs(nearest.kg - anchor.kg) > 0.1;
    })).toBe(true);
  });

  it("is globally monotone and smooth in log-time", () => {
    const points = sampleDisplayCurve(model, 1, 120, 4_000);
    for (let i = 1; i < points.length; i++) {
      expect(points[i]!.kg).toBeLessThanOrEqual(points[i - 1]!.kg + 1e-9);
      expect(points[i]!.kg).toBeLessThanOrEqual(model.maxF);
    }
    const slopes = points.slice(1).map((p, i) =>
      (p.kg - points[i]!.kg) / (Math.log(p.durationS) - Math.log(points[i]!.durationS)));
    for (let i = 1; i < slopes.length; i++) {
      expect(Math.abs(slopes[i]! - slopes[i - 1]!)).toBeLessThan(0.12);
    }
  });

  it("falls back to the measured envelope when no Hill fit is available", () => {
    const sparse = { ...model, cf: null, wPrime: null, capabilityFit: undefined };
    const points = sampleDisplayCurve(sparse, 1, 120, 20);
    expect(points).toHaveLength(21);
    expect(points[0]!.kg).toBe(40);
    expect(points.at(-1)!.kg).toBe(21);
    for (let i = 1; i < points.length; i++) {
      expect(points[i]!.kg).toBeLessThanOrEqual(points[i - 1]!.kg);
    }
  });

  it("draws no line from a single unsupported observation", () => {
    const onePoint = { ...model, points: [{ windowS: 1, kg: 40 }], capabilityFit: undefined };
    expect(sampleDisplayCurve(onePoint, 1, 1, 20)).toEqual([]);
  });

  it("defensively removes increasing noise without overshooting", () => {
    const noisyPoints = [{ windowS: 1, kg: 38 }, { windowS: 3, kg: 40 }, { windowS: 10, kg: 30 }];
    const noisy = { ...model, points: noisyPoints, capabilityFit: fitCapabilityRegression(noisyPoints, 20)! };
    const points = sampleDisplayCurve(noisy, 1, 120, 100);
    expect(Math.max(...points.map((p) => p.kg))).toBeLessThanOrEqual(noisy.maxF);
    for (let i = 1; i < points.length; i++) expect(points[i]!.kg).toBeLessThanOrEqual(points[i - 1]!.kg);
  });

  it("evaluates smoothly across any requested sub-axis", () => {
    const points = sampleDisplayCurve(model, 1, 13, 100);
    expect(points[0]!.durationS).toBe(1);
    expect(points.at(-1)!.durationS).toBeCloseTo(13, 10);
  });

  it("matches rounded Power Endurance and Auto targets at the exact chart duration", () => {
    const at60 = sampleDisplayCurve(model, 60, 60, 1)[0]!.kg;
    expect(zoneTarget(model, "power-endurance")!.targetKg).toBe(Math.round(at60 * 10) / 10);
    const preset: TindeqPreset = {
      id: "curve", name: "Curve", holdS: 5, holdsS: [5, 15, 60], reps: 1, sets: 3,
      restRepsS: 0, restSetsS: 60, targetKg: null, targetPct: null, pctBasis: "pr",
      pctStep: 0, targetCurve: true, alternateSides: false,
    };
    const refs = { prKg: null, cf: model.cf, wPrime: model.wPrime, maxF: model.maxF, capabilityFit: model.capabilityFit };
    for (const [index, durationS] of preset.holdsS!.entries()) {
      const chartKg = sampleDisplayCurve(model, durationS, durationS, 1)[0]!.kg;
      expect(presetTargetKg(preset, refs, index + 1)).toBe(Math.round(chartKg * 10) / 10);
    }
  });
});

describe("sampleDisplayBand", () => {
  it("smoothly spans both supported endpoints without crossing", () => {
    const points = model.points.map((p) => ({
      ...p,
      lowKg: p.kg - 2,
      highKg: p.kg + 1,
    }));
    const band = sampleDisplayBand(points, 200);
    expect(band[0]!.durationS).toBe(1);
    expect(band.at(-1)!.durationS).toBe(120);
    expect(band.length).toBe(points.length);
    expect(band.every((p) => p.lowKg <= p.highKg)).toBe(true);
  });
});

describe("qualityRegions", () => {
  it("derives every cell from classifyZoneLoaded", () => {
    const regions = qualityRegions(model, 1, 120, 44);
    expect(new Set(regions.map((r) => r.quality))).toEqual(
      new Set(["power", "strength", "power-endurance", "endurance"]),
    );
    for (const r of regions) {
      expect(r.quality).toBe(
        classifyZoneLoaded((r.t0 + r.t1) / 2, (r.kg0 + r.kg1) / 2, {
          maxF: model.maxF,
          cf: model.cf,
        }),
      );
    }
  });

  it("honours exact duration and load boundaries", () => {
    const regions = qualityRegions(model, 1, 120, 44);
    expect(regions.some((r) => r.quality === "power" && r.t1 === 6 && r.kg0 === 36)).toBe(true);
    expect(regions.filter((r) => r.t0 >= 20).every((r) => r.quality === "endurance")).toBe(true);
  });
});
