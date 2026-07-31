import type {
  ForceCurveConfidencePoint,
  ForceCurveModel,
  TrainingQuality,
} from "./force-curve";
import { classifyZoneLoaded } from "./zoneHistory";
import { sampleDisplayRegression } from "./forceCurveRegression";

export interface DisplayCurvePoint { durationS: number; kg: number }
export interface DisplayBandPoint { durationS: number; lowKg: number; highKg: number }
export interface QualityRegion { quality: TrainingQuality; t0: number; t1: number; kg0: number; kg1: number }

/** Smooth parametric display regression; CF/W′ is untouched. */
export function sampleDisplayCurve(
  model: ForceCurveModel,
  tMin: number,
  tMax: number,
  steps = 64,
): DisplayCurvePoint[] {
  if (!(tMin > 0) || !(tMax >= tMin) || steps < 1) return [];
  if (!model.displayFit) return [];
  return sampleDisplayRegression(model.displayFit, tMin, tMax, steps);
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
