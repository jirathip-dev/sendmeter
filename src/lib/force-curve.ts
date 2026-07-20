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

/// Which recordings feed the curve fit (SL-80). The old "latest 15" broke on
/// real training: a session of many short reps evicted every long hold from
/// the window, the ≥10s fit points vanished, and CF collapsed to null (zones
/// + auto-CF targets gone). Instead pick per-DURATION-BUCKET bests over a
/// longer window, and always keep the longest efforts — short-rep floods
/// can't starve the long end of the curve.
export interface CurveCandidate {
  id: string;
  durationMs: number;
  avgKg: number;
  recordedAt: string; // ISO timestamp
}

const PICK_WINDOW_DAYS = 90;
const PICK_PER_BUCKET = 3;
const PICK_LONGEST = 3;
// Bucket edges in seconds — roughly log-spaced over CURVE_WINDOWS_S.
const PICK_BUCKETS_S = [5, 10, 20, 45, 90];

function durationBucket(durationMs: number): number {
  const s = durationMs / 1000;
  for (let i = 0; i < PICK_BUCKETS_S.length; i++) {
    if (s < PICK_BUCKETS_S[i]!) return i;
  }
  return PICK_BUCKETS_S.length;
}

export function pickCurveRecordings<T extends CurveCandidate>(
  recs: T[],
  nowMs: number = Date.now(),
  opts: { windowDays?: number; fallbackToAll?: boolean } = {},
): T[] {
  const windowDays = opts.windowDays ?? PICK_WINDOW_DAYS;
  const fallbackToAll = opts.fallbackToAll ?? true;
  const cutoff = nowMs - windowDays * 86_400_000;
  const recent = recs.filter((r) => Date.parse(r.recordedAt) >= cutoff);
  // A dormant exercise keeps its old curve rather than losing it entirely —
  // except for the strict period overlays, where an empty window means an
  // honestly absent curve.
  if (recent.length === 0 && !fallbackToAll) return [];
  const pool = recent.length > 0 ? recent : recs;

  const picked = new Map<string, T>();
  const byBucket = new Map<number, T[]>();
  for (const r of pool) {
    const b = durationBucket(r.durationMs);
    const list = byBucket.get(b);
    if (list) list.push(r);
    else byBucket.set(b, [r]);
  }
  for (const list of byBucket.values()) {
    list.sort((a, b) => b.avgKg - a.avgKg);
    for (const r of list.slice(0, PICK_PER_BUCKET)) picked.set(r.id, r);
  }
  // The hyperbola's long end needs the longest efforts regardless of load.
  for (const r of [...pool].sort((a, b) => b.durationMs - a.durationMs).slice(0, PICK_LONGEST)) {
    picked.set(r.id, r);
  }
  return [...picked.values()];
}

export function computeForceCurve(
  recordings: TindeqSample[][],
  opts: { fitDepth?: number } = {},
): ForceCurveModel | null {
  // How many efforts per window feed the regression. 1 = the old
  // envelope-only fit; the default 3 regresses over the top few efforts of
  // each duration, so the fit reflects repeated performance instead of a
  // single lucky pull (SL-80b).
  const fitDepth = opts.fitDepth ?? 3;
  const points: ForceCurvePoint[] = [];
  const xs: number[] = [];
  const ys: number[] = [];
  const fitWindows = new Set<number>();
  for (const w of CURVE_WINDOWS_S) {
    const vals: number[] = [];
    for (const samples of recordings) {
      const v = meanMaxForce(samples, w);
      if (v !== null && v > 0) vals.push(v);
    }
    if (vals.length === 0) continue;
    vals.sort((a, b) => b - a);
    // Chart still shows the best-effort envelope per window…
    points.push({ windowS: w, kg: Math.round(vals[0]! * 100) / 100 });
    // …but the CF regression sees the top-K efforts of every long window.
    if (w >= FIT_MIN_WINDOW_S) {
      for (const v of vals.slice(0, fitDepth)) {
        xs.push(1 / w);
        ys.push(v);
      }
      fitWindows.add(w);
    }
  }
  if (points.length === 0) return null;

  const maxF = Math.max(...points.map((p) => p.kg));

  // Critical-force fit: F = CF + W'·(1/t) over long windows. Still requires
  // ≥3 DISTINCT windows — many efforts at one duration can't anchor a line.
  let cf: number | null = null;
  let wPrime: number | null = null;
  if (fitWindows.size >= FIT_MIN_POINTS) {
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

/// Trailing windows for the curve-shift overlays (SL-80c): how has the
/// force–duration curve moved over time?
export const CURVE_PERIODS = [
  { label: "30d", days: 30 },
  { label: "90d", days: 90 },
  { label: "180d", days: 180 },
  { label: "1y", days: 365 },
  { label: "2y", days: 730 },
  { label: "3y", days: 1095 },
] as const;

export interface PeriodCurve {
  label: string;
  days: number;
  model: ForceCurveModel | null;
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

/// Timer prescription per zone (matches the protocol strings in zoneTarget):
/// pull time, rest between reps, reps, sets, rest between sets. Drives the
/// guided fullscreen countdown when a zone target is armed.
export const ZONE_PROTOCOLS: Record<
  TrainingQuality,
  { holdS: number; restRepsS: number; reps: number; sets: number; restSetsS: number }
> = {
  power: { holdS: 5, restRepsS: 150, reps: 6, sets: 1, restSetsS: 0 },
  strength: { holdS: 10, restRepsS: 150, reps: 5, sets: 1, restSetsS: 0 },
  "power-endurance": { holdS: 7, restRepsS: 3, reps: 6, sets: 4, restSetsS: 120 },
  endurance: { holdS: 30, restRepsS: 30, reps: 8, sets: 1, restSetsS: 0 },
};

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
