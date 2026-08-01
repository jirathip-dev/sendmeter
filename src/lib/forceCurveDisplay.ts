import type {
  ForceCurveConfidencePoint,
  ForceCurveModel,
  TrainingQuality,
} from "./force-curve";
import { classifyZoneLoaded } from "./zoneHistory";
import { predictCapability } from "./force-curve";

export interface DisplayCurvePoint { durationS: number; kg: number }
export interface DisplayBandPoint { durationS: number; lowKg: number; highKg: number }
export interface QualityRegion { quality: TrainingQuality; t0: number; t1: number; kg0: number; kg1: number }

/**
 * Smooth SVG sampling. When a constrained Hill capability fit
 * is unavailable, fall back to a log-time interpolation of the measured
 * envelope instead of fabricating a model or drawing the old max-force cap.
 */
export function sampleDisplayCurve(
  model: ForceCurveModel,
  tMin: number,
  tMax: number,
  steps = 64,
): DisplayCurvePoint[] {
  if (!(tMin > 0) || !(tMax >= tMin) || steps < 1) return [];
  if (model.capabilityFit) {
    const fitted = Array.from({ length: steps + 1 }, (_, i) => {
      const durationS = Math.exp(
        Math.log(tMin) + ((Math.log(tMax) - Math.log(tMin)) * i) / steps,
      );
      const kg = predictCapability(model, durationS);
      return kg === null ? null : { durationS, kg };
    });
    if (fitted.every((point) => point !== null)) return fitted;
  }

  const anchors = [...model.points]
    .filter((point) => point.windowS > 0 && point.kg > 0)
    .sort((a, b) => a.windowS - b.windowS)
    .map((point, index, points) => ({
      durationS: point.windowS,
      kg: Math.min(model.maxF, point.kg, index === 0 ? Infinity : points[index - 1]!.kg),
    }));
  for (let i = 1; i < anchors.length; i++) {
    anchors[i]!.kg = Math.min(anchors[i - 1]!.kg, anchors[i]!.kg);
  }
  if (anchors.length < 2) return [];

  const interpolate = (durationS: number): number => {
    if (durationS <= anchors[0]!.durationS) return anchors[0]!.kg;
    if (durationS >= anchors.at(-1)!.durationS) return anchors.at(-1)!.kg;
    const upper = anchors.findIndex((point) => point.durationS >= durationS);
    const a = anchors[upper - 1]!;
    const b = anchors[upper]!;
    const fraction =
      (Math.log(durationS) - Math.log(a.durationS)) /
      (Math.log(b.durationS) - Math.log(a.durationS));
    return a.kg + (b.kg - a.kg) * fraction;
  };

  return Array.from({ length: steps + 1 }, (_, i) => {
    const durationS = Math.exp(
      Math.log(tMin) + ((Math.log(tMax) - Math.log(tMin)) * i) / steps,
    );
    return { durationS, kg: interpolate(durationS) };
  });
}

/** Bootstrap percentiles are already evaluated on a dense log-time grid. */
export function sampleDisplayBand(
  points: ForceCurveConfidencePoint[],
  steps = 64,
): DisplayBandPoint[] {
  void steps;
  return points.map((p) => ({ durationS: p.windowS, lowKg: p.lowKg, highKg: p.highKg }));
}

export function qualityRegions(model: ForceCurveModel, tMin: number, tMax: number, yMax: number): QualityRegion[] {
  const xs = [tMin, 6, 20, tMax].filter((v) => v >= tMin && v <= tMax);
  const ys = [0, model.cf, 0.8 * model.maxF, 0.9 * model.maxF, yMax]
    .filter((v): v is number => v != null && v >= 0 && v <= yMax);
  const unique = (values: number[]) => [...new Set(values)].sort((a, b) => a - b);
  const xb = unique(xs), yb = unique(ys), regions: QualityRegion[] = [];
  for (let x = 1; x < xb.length; x++) for (let y = 1; y < yb.length; y++) {
    const t0 = xb[x - 1]!, t1 = xb[x]!, kg0 = yb[y - 1]!, kg1 = yb[y]!;
    const quality = classifyZoneLoaded((t0 + t1) / 2, (kg0 + kg1) / 2, { maxF: model.maxF, cf: model.cf });
    if (quality) regions.push({ quality, t0, t1, kg0, kg1 });
  }
  return regions;
}
