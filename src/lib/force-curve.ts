import type { TindeqSample } from "../types";
import { fitDisplayRegression, predictDisplayFit, type DisplayFit } from "./forceCurveRegression";

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
const DISPLAY_BAND_WINDOWS_S = Array.from({ length: 65 }, (_, i) =>
  i === 0 ? 1 : i === 64 ? 120 : Math.exp(Math.log(120) * i / 64));
const RESAMPLE_HZ = 10;
const FIT_MIN_WINDOW_S = 10;
const FIT_MIN_POINTS = 3;

export interface ForceCurvePoint {
  windowS: number;
  kg: number;
}

export interface ForceCurveModel {
  points: ForceCurvePoint[]; // best-effort envelope per window, ascending
  /// EVERY recording's mean-max per window — the raw scatter behind the
  /// envelope, so the chart can show the full spread of efforts, not just
  /// the best (optional: absent on hand-built models in tests).
  scatter?: ForceCurvePoint[];
  maxF: number; // best short-window force (kg)
  cf: number | null; // critical force (kg); null = not enough long holds
  wPrime: number | null; // impulse above CF (kg·s)
  confidenceBand?: ForceCurveConfidencePoint[];
  coverage?: ForceCurveCoverage;
  displayFit?: DisplayFit;
}

export interface ForceCurveConfidencePoint extends ForceCurvePoint {
  lowKg: number;
  highKg: number;
}

export interface ForceCurveCoverage {
  quality: "weak" | "fair" | "strong";
  longestS: number;
  distinctFitWindows: number;
  independentDurations: number;
  message: string;
}

export interface ForceCurveEffort {
  samples: TindeqSample[];
  recordedAt?: string;
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

type FitRow = { x: number; y: number; weight: number };

function weightedLine(rows: FitRow[]): { cf: number; wPrime: number } | null {
  const sw = rows.reduce((sum, r) => sum + r.weight, 0);
  if (sw <= 0) return null;
  const mx = rows.reduce((sum, r) => sum + r.weight * r.x, 0) / sw;
  const my = rows.reduce((sum, r) => sum + r.weight * r.y, 0) / sw;
  let sxx = 0, sxy = 0;
  for (const r of rows) {
    sxx += r.weight * (r.x - mx) ** 2;
    sxy += r.weight * (r.x - mx) * (r.y - my);
  }
  if (sxx <= 1e-12) return null;
  const wPrime = sxy / sxx;
  const cf = my - wPrime * mx;
  return cf > 0 && wPrime >= 0 ? { cf, wPrime } : null;
}

function percentile(sorted: number[], p: number): number {
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.floor(p * sorted.length)))]!;
}

interface PreparedEffort {
  values: (number | null)[];
  freshness: number;
  durationMs: number;
}

export interface ForceCurveDiagnostics {
  meanMaxEvaluations: number;
}

function coverageFor(points: ForceCurvePoint[], distinctFitWindows: number, efforts: PreparedEffort[]): ForceCurveCoverage {
  const longestS = points.at(-1)?.windowS ?? 0;
  const independentDurations = new Set(efforts
    .map((e) => e.durationMs)
    .filter((ms) => ms >= FIT_MIN_WINDOW_S * 1000)
    .map((ms) => durationBucket(ms))).size;
  if (longestS < 30 || distinctFitWindows < 3 || independentDurations < 2) return {
    quality: "weak", longestS, distinctFitWindows, independentDurations,
    message: longestS < 30
      ? `Weak duration coverage: longest evidence is ${longestS}s. Add an all-out 30–60s hold.`
      : `Weak duration coverage: evidence comes from only ${independentDurations} duration range${independentDurations === 1 ? "" : "s"}. Add an all-out hold at a distinctly different duration.`,
  };
  if (longestS < 60 || distinctFitWindows < 5 || independentDurations < 3) return {
    quality: "fair", longestS, distinctFitWindows, independentDurations,
    message: `Fair duration coverage: a 60s+ all-out hold would narrow the estimate.`,
  };
  return { quality: "strong", longestS, distinctFitWindows, independentDurations, message: "Strong duration coverage." };
}

function normalizedEfforts(recordings: (TindeqSample[] | ForceCurveEffort)[]): ForceCurveEffort[] {
  return recordings.map((r) => Array.isArray(r) ? { samples: r } : r);
}

function prepareEfforts(
  efforts: ForceCurveEffort[],
  nowMs: number,
  diagnostics?: ForceCurveDiagnostics,
): PreparedEffort[] {
  return efforts.map((effort) => {
    const ageDays = effort.recordedAt == null
      ? 0
      : Math.max(0, (nowMs - Date.parse(effort.recordedAt)) / 86_400_000);
    const freshness = Number.isFinite(ageDays) ? 2 ** (-ageDays / 120) : 1;
    const values = CURVE_WINDOWS_S.map((windowS) => {
      if (diagnostics) diagnostics.meanMaxEvaluations++;
      return meanMaxForce(effort.samples, windowS);
    });
    return { values, freshness, durationMs: effort.samples.at(-1)?.t ?? 0 };
  });
}

function computeCurveCore(
  efforts: PreparedEffort[],
  opts: { fitDepth: number },
): ForceCurveModel | null {
  // How many efforts per window feed the regression. 1 = the old
  // envelope-only fit; the default 3 regresses over the top few efforts of
  // each duration, so the fit reflects repeated performance instead of a
  // single lucky pull (SL-80b).
  const points: ForceCurvePoint[] = [];
  const scatter: ForceCurvePoint[] = [];
  const rows: FitRow[] = [];
  const fitWindows = new Set<number>();
  for (let windowIndex = 0; windowIndex < CURVE_WINDOWS_S.length; windowIndex++) {
    const w = CURVE_WINDOWS_S[windowIndex]!;
    const vals: { value: number; freshness: number }[] = [];
    for (const effort of efforts) {
      const v = effort.values[windowIndex]!;
      if (v !== null && v > 0) {
        // A 120-day half-life preserves old long-duration evidence but stops
        // it carrying the same authority as a current maximal test.
        vals.push({ value: v, freshness: effort.freshness });
      }
    }
    if (vals.length === 0) continue;
    vals.sort((a, b) => b.value - a.value);
    // Every effort lands in the scatter…
    for (const v of vals) scatter.push({ windowS: w, kg: Math.round(v.value * 100) / 100 });
    // …the envelope keeps the best per window…
    const best = vals[0]!.value;
    points.push({ windowS: w, kg: Math.round(best * 100) / 100 });
    // …but the CF regression sees the top-K efforts of every long window.
    if (w >= FIT_MIN_WINDOW_S) {
      const selected = vals.slice(0, opts.fitDepth);
      const raw = selected.map((v) => {
        // Clearly submaximal attempts retain a small voice rather than being
        // silently discarded. Fourth power strongly discounts <80% efforts.
        const maximality = Math.max(0.08, (v.value / best) ** 4);
        return { v, weight: v.freshness * maximality };
      });
      const windowWeight = raw.reduce((sum, r) => sum + r.weight, 0);
      for (const r of raw) {
        // Normalize each duration window to total weight 1. A flood of short
        // reps therefore cannot overpower scarce long-duration evidence.
        rows.push({ x: 1 / w, y: r.v.value, weight: r.weight / windowWeight });
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
    const fit = weightedLine(rows);
    if (fit) {
      cf = Math.round(fit.cf * 100) / 100;
      wPrime = Math.round(fit.wPrime * 100) / 100;
    }
  }
  const displayFit = fitDisplayRegression(points, cf);
  return { points, scatter, maxF, cf, wPrime, displayFit: displayFit ?? undefined, coverage: coverageFor(points, fitWindows.size, efforts) };
}

export function computeForceCurve(
  recordings: (TindeqSample[] | ForceCurveEffort)[],
  opts: {
    fitDepth?: number;
    nowMs?: number;
    bootstrapSamples?: number;
    diagnostics?: ForceCurveDiagnostics;
  } = {},
): ForceCurveModel | null {
  const efforts = normalizedEfforts(recordings);
  const fitDepth = opts.fitDepth ?? 3;
  const nowMs = opts.nowMs ?? Date.now();
  const prepared = prepareEfforts(efforts, nowMs, opts.diagnostics);
  const model = computeCurveCore(prepared, { fitDepth });
  if (!model || model.cf == null || efforts.length < 3) return model;

  // Recording-level bootstrap: resample whole efforts, never the correlated
  // rolling windows within an effort. A fixed LCG seed makes UI/tests stable.
  let state = 0x352c0de;
  const random = () => ((state = (Math.imul(state, 1664525) + 1013904223) >>> 0) / 2 ** 32);
  const predictions = new Map(DISPLAY_BAND_WINDOWS_S.map((w) => [w, [] as number[]]));
  const iterations = opts.bootstrapSamples ?? 200;
  for (let b = 0; b < iterations; b++) {
    const sample = Array.from({ length: prepared.length }, () => prepared[Math.floor(random() * prepared.length)]!);
    const fitted = computeCurveCore(sample, { fitDepth });
    if (fitted?.cf == null || fitted.wPrime == null) continue;
    for (const w of DISPLAY_BAND_WINDOWS_S) {
      // Refit the display regression for each whole-recording resample, then
      // evaluate it over the chart's full domain. The tail is model-based
      // extrapolation when a replicate lacks long evidence; the coverage flag
      // tells the UI when that part of the interval deserves less confidence.
      if (fitted.displayFit) predictions.get(w)!.push(predictDisplayFit(fitted.displayFit, w));
    }
  }
  const confidenceBand = DISPLAY_BAND_WINDOWS_S.flatMap((windowS) => {
    const values = predictions.get(windowS)!.sort((a, b) => a - b);
    return values.length < Math.max(20, iterations * 0.2) ? [] : [{
      windowS,
      kg: model.displayFit ? predictDisplayFit(model.displayFit, windowS) : model.points.find((p) => p.windowS === windowS)!.kg,
      lowKg: percentile(values, 0.025),
      highKg: percentile(values, 0.975),
    }];
  });
  return { ...model, confidenceBand: confidenceBand.length ? confidenceBand : undefined };
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
  if (model.displayFit) return predictDisplayFit(model.displayFit, tS);
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

/// Every zone a RECORDING can carry (#297/#325), vs. `TrainingQuality`'s four
/// TRAINABLE qualities that key `ZONE_PROTOCOLS`/`zoneSetDurationS`/
/// `classifyZone`/the balance code. Maintenance protocols are deliberately
/// NOT training qualities: they have no set-duration divisor and are always
/// recorded explicitly rather than inferred from duration/load.
export type MaintenanceZone = "warmup" | "prehab";
export type RecordedZone = TrainingQuality | MaintenanceZone;

export function isMaintenanceZone(
  zone: RecordedZone | null,
): zone is MaintenanceZone {
  return zone === "warmup" || zone === "prehab";
}

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
  // #320: modeled as 1 rep × 8 sets so each 30s recovery is a set boundary.
  endurance: { holdS: 30, restRepsS: 0, reps: 1, sets: 8, restSetsS: 30 },
};

// ---------------------------------------------------------------------------
// Adjustable intensity (SL-97): scaling the target load down/up automatically
// extends/shortens the hold time so the training dose stays equivalent,
// derived from the same critical-force model. All pure — the UI only stores
// the chosen pct and calls back in here.

export const ZONE_INTENSITY = { min: 60, max: 110, step: 5, default: 100 } as const;

function clamp(v: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, v));
}

function clampIntensity(pct: number): number {
  return clamp(pct, ZONE_INTENSITY.min, ZONE_INTENSITY.max);
}

/// Hold times <20s round to the nearest second; ≥20s round to the nearest 5s
/// (matches how the base protocols are already specified: 5/7/10s vs 30s).
function roundHoldS(s: number): number {
  return s < 20 ? Math.round(s) : Math.round(s / 5) * 5;
}

const HOLD_CLAMP_S: Record<Exclude<TrainingQuality, "endurance">, [number, number]> = {
  power: [3, 15],
  strength: [5, 30],
  "power-endurance": [5, 15],
};

/// Adjusted hold for the above-CF zones (power/strength/power-endurance):
/// scaling load down should extend the hold so the per-rep training dose —
/// impulse above CF (W′ cost), or plain force×time without a CF fit — stays
/// constant.
function adjustedHoldAboveCf(
  quality: Exclude<TrainingQuality, "endurance">,
  model: ForceCurveModel,
  baseKg: number,
  newKg: number,
  baseHoldS: number,
): number {
  const [lo, hi] = HOLD_CLAMP_S[quality];
  let holdS: number;
  if (model.cf !== null && model.wPrime !== null && baseKg > model.cf) {
    if (newKg > model.cf) {
      // Constant W′ cost: (F − CF) × t stays fixed.
      holdS = ((baseKg - model.cf) * baseHoldS) / (newKg - model.cf);
    } else {
      // Very low intensity — at/below CF the W′ cost is undefined (the hold
      // could run indefinitely); cap at the zone's longest allowed hold.
      holdS = hi;
    }
  } else {
    // No CF fit (or the odd case where even the 100% target sits at/below
    // CF) — impulse-preserving fallback: force × time held constant.
    holdS = (baseHoldS * baseKg) / newKg;
  }
  return roundHoldS(clamp(holdS, lo, hi));
}

/// Adjusted hold + sets for endurance: a pure heuristic of `pct`, holding
/// total time-under-tension (sets × hold) roughly constant as intensity
/// scales — hold grows with the square of `100/pct`, sets shrink to
/// compensate (reps stays 1 — see #320: the protocol shape is 1 rep × 8
/// sets so alternation fires per hold). Deliberately NOT derived from the
/// F(t) = CF + W′/t curve the above-CF zones use (adjustedHoldAboveCf):
/// endurance targets sit at/below CF (zoneTarget's 80–100% of CF), where
/// that hyperbola isn't valid — it models the finite W′ reservoir above CF,
/// which doesn't exist down here.
/// Exported for direct testing of the [20, 240]s clamp (unreachable through
/// zoneTarget/zonePrescription alone since those clamp pct to [60, 110] first).
export function adjustedEndurance(
  baseHoldS: number,
  baseSets: number,
  pct: number,
): { holdS: number; sets: number } {
  const rawHoldS = baseHoldS * (100 / pct) ** 2;
  const holdS = roundHoldS(clamp(rawHoldS, 20, 240));
  const sets = clamp(Math.round((baseSets * baseHoldS) / holdS), 1, baseSets);
  return { holdS, sets };
}

export function zoneTarget(
  model: ForceCurveModel,
  quality: TrainingQuality,
  intensityPct = 100,
): ZoneTarget | null {
  const round1 = (v: number) => Math.round(v * 10) / 10;
  const pct = clampIntensity(intensityPct);
  const scale = pct / 100;
  const suffix = pct === 100 ? "" : ` · intensity ${pct}%`;
  switch (quality) {
    case "power": {
      const baseKg = round1(model.maxF * 0.95);
      const newKg = round1(baseKg * scale);
      return {
        quality,
        label: "Power",
        targetKg: newKg,
        lowKg: round1(model.maxF * 0.9 * scale),
        highKg: round1(model.maxF * scale),
        workS: adjustedHoldAboveCf("power", model, baseKg, newKg, ZONE_PROTOCOLS.power.holdS),
        protocol: "5s max pulls · full recovery (2–3 min) · 5–8 reps",
        basis: `90–100% of your best short-window force (${round1(model.maxF)} kg)${suffix}`,
      };
    }
    case "strength": {
      const baseKg = round1(model.maxF * 0.85);
      const newKg = round1(baseKg * scale);
      return {
        quality,
        label: "Strength",
        targetKg: newKg,
        lowKg: round1(model.maxF * 0.8 * scale),
        highKg: round1(model.maxF * 0.9 * scale),
        workS: adjustedHoldAboveCf("strength", model, baseKg, newKg, ZONE_PROTOCOLS.strength.holdS),
        protocol: "7–10s holds · 2–3 min rest · 4–6 reps",
        basis: `80–90% of max (${round1(model.maxF)} kg)${suffix}`,
      };
    }
    case "power-endurance": {
      if (model.cf === null || model.wPrime === null) return null;
      const f60 = predictForce(model, 60);
      const baseKg = round1(f60);
      const newKg = round1(baseKg * scale);
      return {
        quality,
        label: "Power Endurance",
        targetKg: newKg,
        lowKg: round1(f60 * 0.93 * scale),
        highKg: round1(f60 * 1.07 * scale),
        workS: adjustedHoldAboveCf(
          "power-endurance",
          model,
          baseKg,
          newKg,
          ZONE_PROTOCOLS["power-endurance"].holdS,
        ),
        protocol: "repeaters 7s on / 3s off × 6 · 2 min rest · 3–5 sets",
        basis: model.displayFit
          ? `Hill capability curve at 60s (${round1(f60)} kg)${suffix}`
          : `legacy force estimate at 60s: CF ${round1(model.cf)} + W′/60${suffix}`,
      };
    }
    case "endurance": {
      if (model.cf === null) return null;
      const baseKg = round1(model.cf * 0.9);
      const newKg = round1(baseKg * scale);
      const { holdS } = adjustedEndurance(ZONE_PROTOCOLS.endurance.holdS, ZONE_PROTOCOLS.endurance.sets, pct);
      return {
        quality,
        label: "Endurance",
        targetKg: newKg,
        lowKg: round1(model.cf * 0.8 * scale),
        highKg: round1(model.cf * scale),
        workS: holdS,
        protocol: "30s on / 30s off × 6–10, or continuous 3–10 min",
        basis: `80–100% of critical force (${round1(model.cf)} kg)${suffix}`,
      };
    }
  }
}

export interface ZonePrescription {
  target: ZoneTarget;
  holdS: number;
  reps: number;
  sets: number;
  restRepsS: number;
  restSetsS: number;
}

/// Full adjusted prescription for an armed zone — the gauge band (`target`)
/// plus the guided-timer numbers, all derived from one pct (pure; consumed
/// by zoneSelection.ts so callers touch a single function).
export function zonePrescription(
  model: ForceCurveModel,
  quality: TrainingQuality,
  intensityPct = 100,
): ZonePrescription | null {
  const target = zoneTarget(model, quality, intensityPct);
  if (!target) return null;
  const zp = ZONE_PROTOCOLS[quality];
  if (quality === "endurance") {
    const { holdS, sets } = adjustedEndurance(zp.holdS, zp.sets, clampIntensity(intensityPct));
    return { target, holdS, reps: zp.reps, sets, restRepsS: zp.restRepsS, restSetsS: zp.restSetsS };
  }
  return {
    target,
    holdS: target.workS,
    reps: zp.reps,
    sets: zp.sets,
    restRepsS: zp.restRepsS,
    restSetsS: zp.restSetsS,
  };
}

// ---------------------------------------------------------------------------
// Warm-up (#297 Part B2): a short finger-specific primer to use AFTER general
// movement and easy climbing, not as a replacement for either. The dose ramps
// both duration and load without accumulating training volume: two reps per
// set at 5s/7s/10s and 40%/55%/70% of the exercise PR, with enough rest to
// keep the last pulls crisp. The evidence supports progressive,
// climbing-specific warm-up but does not establish one dynamometer protocol,
// so the user-facing basis says this is a conservative product prescription.
// It is recorded under its own maintenance zone and excluded from training
// balance/curve/PR calculations.
export const WARMUP_PROTOCOL = {
  holdS: 5,
  holdsS: [5, 7, 10],
  reps: 2,
  sets: 3,
  restRepsS: 15,
  restSetsS: 60,
  targetPct: 40,
  pctStep: 15,
  pctBasis: "pr",
} as const;

export interface WarmupTarget {
  targetKg: number;
  finalTargetKg: number;
  lowKg: number;
  highKg: number;
  workS: number;
  label: string;
  basis: string;
}

/// Initial live-gauge band plus the final ramp target. The guided protocol
/// resolves every set from `% of PR`; this model-based preview uses the same
/// best short-window reference that unlocks the recommended card.
export function warmupTarget(
  model: ForceCurveModel,
  prKg = model.maxF,
): WarmupTarget | null {
  if (prKg <= 0) return null;
  const round1 = (v: number) => Math.round(v * 10) / 10;
  const firstPct = WARMUP_PROTOCOL.targetPct;
  const finalPct = firstPct + (WARMUP_PROTOCOL.sets - 1) * WARMUP_PROTOCOL.pctStep;
  const targetKg = round1(prKg * firstPct / 100);
  const finalTargetKg = round1(prKg * finalPct / 100);
  return {
    targetKg,
    finalTargetKg,
    lowKg: round1(targetKg * 0.9),
    highKg: round1(targetKg * 1.1),
    workS: WARMUP_PROTOCOL.holdS,
    label: "Warm-up",
    basis:
      `${firstPct}% → ${finalPct}% of your best short-window force ` +
      `(${round1(prKg)} kg), with 5s → 7s → 10s holds. A conservative ` +
      "finger-specific primer after general movement and easy climbing — not a complete warm-up or clinical prescription.",
  };
}

// ---------------------------------------------------------------------------
// Prehab (#325, split from #297 as Part B1): a low-load, long-hold,
// daily-repeatable finger-tendon maintenance session — recorded under its own
// "prehab" zone (see RecordedZone above) so it counts toward NOTHING in
// training balance rather than being inferred back into training credit.
//
// Numbers approved on #297: 30s × 4 reps, 90s rest between reps, one set, at
// 0.70 × critical force (0.30 × maxF when CF isn't fitted yet). Baar's tendon
// work puts the refractory ceiling at ~10 min of loading and demonstrates
// four 30s holds over an ~8 min window; 30s is the duration sweet spot (past
// it, 2 min adds only ~15% more stiffness adaptation), and long-duration
// isometrics produce greater stiffness adaptation than short ones at equal
// volume. Load stays below CF deliberately — inside this window the loading
// signal is largely load-independent, so there's no reason to buy adaptation
// with fatigue when daily (or twice-daily, ≥6h apart) repeatability is the
// point. The two load figures agree by construction: CF ≈ 41% MVC, and
// 0.70 × 0.41 ≈ 0.29 ≈ 0.30 × maxF.
//
// Nobody has published prehab numbers for a finger dynamometer — `basis`
// below says so; this is derived from the user's own curve and shaped by
// tendon-loading research, not a citation.
export const PREHAB_PROTOCOL = {
  holdS: 30,
  reps: 4,
  sets: 1,
  restRepsS: 90,
  restSetsS: 0,
} as const;

export interface PrehabTarget {
  targetKg: number;
  lowKg: number;
  highKg: number;
  workS: number;
  label: string;
  basis: string;
}

/// The Prehab load band for this exercise: 0.70 × CF, falling back to
/// 0.30 × maxF when there's no CF fit yet. Null when neither is usable (no
/// model, or a model with maxF <= 0) — Prehab has nothing to anchor to.
export function prehabTarget(model: ForceCurveModel): PrehabTarget | null {
  const round1 = (v: number) => Math.round(v * 10) / 10;
  let baseKg: number;
  let basis: string;
  if (model.cf !== null) {
    baseKg = model.cf * 0.7;
    basis = `70% of your critical force (${round1(model.cf)} kg)`;
  } else if (model.maxF > 0) {
    baseKg = model.maxF * 0.3;
    basis = `30% of your best short-window force (${round1(model.maxF)} kg) — critical force isn't fitted yet`;
  } else {
    return null;
  }
  return {
    targetKg: round1(baseKg),
    lowKg: round1(baseKg * 0.9),
    highKg: round1(baseKg * 1.1),
    workS: PREHAB_PROTOCOL.holdS,
    label: "Prehab",
    basis:
      `${basis}, deliberately below critical force. Derived from your own ` +
      "force curve and shaped by tendon-loading research (Baar) — not a " +
      "clinical prescription; nobody has published prehab numbers for a " +
      "finger dynamometer.",
  };
}
