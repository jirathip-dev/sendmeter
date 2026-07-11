import type { TindeqSample } from "../types";

/**
 * Force–duration modeling for isometric finger strength (the isometric
 * analog of the force–velocity curve): for each recording, the best mean
 * force sustained over windows of 1…120 s; aggregated across recordings of
 * one exercise tag; fitted with the critical-force hyperbola
 *
 *   F(t) = CF + W' / t
 *
 * CF = force sustainable "indefinitely" (aerobic ceiling), W' = finite
 * impulse capacity above CF. Fit is linear regression of F against 1/t
 * over windows ≥ FIT_MIN_WINDOW_S (short windows are RFD/peak-dominated
 * and don't follow the hyperbola).
 */

export const CURVE_WINDOWS_S = [1, 3, 5, 7, 10, 15, 20, 30, 45, 60, 90, 120];
const RESAMPLE_HZ = 10;
const FIT_MIN_WINDOW_S = 10;
const FIT_MIN_POINTS = 3;

export interface ForceCurvePoint {
  windowS: number;
  kg: number;
}

export interface ForceCurveModel {
  points: ForceCurvePoint[]; // aggregated mean-max, ascending window
  maxF: number; // best short-window force (kg)
  cf: number | null; // critical force (kg); null = not enough long holds
  wPrime: number | null; // impulse above CF (kg·s)
}

/// Step-resample irregular samples to a fixed grid, then prefix sums make
/// any window mean O(1).
function resample(samples: TindeqSample[]): number[] {
  if (samples.length === 0) return [];
  const stepMs = 1000 / RESAMPLE_HZ;
  const end = samples[samples.length - 1]!.t;
  const grid: number[] = [];
  let i = 0;
  for (let t = 0; t <= end; t += stepMs) {
    while (i + 1 < samples.length && samples[i + 1]!.t <= t) i++;
    grid.push(Math.max(0, samples[i]!.kg));
  }
  return grid;
}

export function meanMaxForce(
  samples: TindeqSample[],
  windowS: number,
): number | null {
  const grid = resample(samples);
  const n = Math.round(windowS * RESAMPLE_HZ);
  if (n < 1 || grid.length < n) return null;
  const prefix = new Array<number>(grid.length + 1);
  prefix[0] = 0;
  for (let i = 0; i < grid.length; i++) prefix[i + 1] = prefix[i]! + grid[i]!;
  let best = -Infinity;
  for (let i = 0; i + n <= grid.length; i++) {
    best = Math.max(best, (prefix[i + n]! - prefix[i]!) / n);
  }
  return best;
}

export function computeForceCurve(
  recordings: TindeqSample[][],
): ForceCurveModel | null {
  const points: ForceCurvePoint[] = [];
  for (const w of CURVE_WINDOWS_S) {
    let best: number | null = null;
    for (const samples of recordings) {
      const v = meanMaxForce(samples, w);
      if (v !== null && (best === null || v > best)) best = v;
    }
    if (best !== null && best > 0) {
      points.push({ windowS: w, kg: Math.round(best * 100) / 100 });
    }
  }
  if (points.length === 0) return null;

  const maxF = Math.max(...points.map((p) => p.kg));

  // Critical-force fit: F = CF + W'·(1/t) over long windows
  const fitPts = points.filter((p) => p.windowS >= FIT_MIN_WINDOW_S);
  let cf: number | null = null;
  let wPrime: number | null = null;
  if (fitPts.length >= FIT_MIN_POINTS) {
    const xs = fitPts.map((p) => 1 / p.windowS);
    const ys = fitPts.map((p) => p.kg);
    const n = xs.length;
    const mx = xs.reduce((a, b) => a + b, 0) / n;
    const my = ys.reduce((a, b) => a + b, 0) / n;
    let sxx = 0;
    let sxy = 0;
    for (let i = 0; i < n; i++) {
      sxx += (xs[i]! - mx) ** 2;
      sxy += (xs[i]! - mx) * (ys[i]! - my);
    }
    if (sxx > 1e-12) {
      const slope = sxy / sxx; // W'
      const intercept = my - slope * mx; // CF
      if (intercept > 0 && slope >= 0) {
        cf = Math.round(intercept * 100) / 100;
        wPrime = Math.round(slope * 100) / 100;
      }
    }
  }

  return { points, maxF, cf, wPrime };
}

export function predictForce(model: ForceCurveModel, tS: number): number {
  if (model.cf === null || model.wPrime === null) return model.maxF;
  return Math.min(model.maxF, model.cf + model.wPrime / tS);
}

// ---------------------------------------------------------------------------
// Training-zone targets derived from the curve. Percentages follow standard
// finger-training prescriptions; every constant is here in one place.

export type TrainingQuality =
  | "power"
  | "strength"
  | "power-endurance"
  | "endurance";

export interface ZoneTarget {
  quality: TrainingQuality;
  label: string;
  targetKg: number;
  lowKg: number;
  highKg: number;
  workS: number;
  protocol: string;
  basis: string; // what the numbers were derived from
}

export const QUALITIES: { id: TrainingQuality; label: string }[] = [
  { id: "power", label: "Power" },
  { id: "strength", label: "Strength" },
  { id: "power-endurance", label: "Pow End" },
  { id: "endurance", label: "Endurance" },
];

export function zoneTarget(
  model: ForceCurveModel,
  quality: TrainingQuality,
): ZoneTarget | null {
  const round1 = (v: number) => Math.round(v * 10) / 10;
  switch (quality) {
    case "power": {
      const t = model.maxF * 0.95;
      return {
        quality,
        label: "Power",
        targetKg: round1(t),
        lowKg: round1(model.maxF * 0.9),
        highKg: round1(model.maxF),
        workS: 5,
        protocol: "5s max pulls · full recovery (2–3 min) · 5–8 reps",
        basis: `90–100% of your best short-window force (${round1(model.maxF)} kg)`,
      };
    }
    case "strength": {
      const t = model.maxF * 0.85;
      return {
        quality,
        label: "Strength",
        targetKg: round1(t),
        lowKg: round1(model.maxF * 0.8),
        highKg: round1(model.maxF * 0.9),
        workS: 10,
        protocol: "7–10s holds · 2–3 min rest · 4–6 reps",
        basis: `80–90% of max (${round1(model.maxF)} kg)`,
      };
    }
    case "power-endurance": {
      if (model.cf === null || model.wPrime === null) return null;
      const f60 = model.cf + model.wPrime / 60;
      return {
        quality,
        label: "Power Endurance",
        targetKg: round1(f60),
        lowKg: round1(f60 * 0.93),
        highKg: round1(f60 * 1.07),
        workS: 7,
        protocol: "repeaters 7s on / 3s off × 6 · 2 min rest · 3–5 sets",
        basis: `force sustainable ~60s: CF ${round1(model.cf)} + W′/60`,
      };
    }
    case "endurance": {
      if (model.cf === null) return null;
      const t = model.cf * 0.9;
      return {
        quality,
        label: "Endurance",
        targetKg: round1(t),
        lowKg: round1(model.cf * 0.8),
        highKg: round1(model.cf),
        workS: 30,
        protocol: "30s on / 30s off × 6–10, or continuous 3–10 min",
        basis: `80–100% of critical force (${round1(model.cf)} kg)`,
      };
    }
  }
}
