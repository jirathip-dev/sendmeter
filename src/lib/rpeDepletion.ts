/**
 * Session RPE predicted from W' depletion (issue #280).
 *
 * KEEP-IN-SYNC: mirrored by `RPEDepletion.swift` in `SendLogWatchCore` —
 * identical constants, identical math, identical rounding, and the SAME test
 * vectors on both sides (`rpeDepletion.test.ts` ↔ `RPEDepletionTests.swift`).
 * The watch predicts the RPE of a gauge session it logs itself, the phone
 * predicts the same number for the same session, and the two must not drift.
 * Only the depletion + mapping is duplicated — the curve FIT itself
 * (`force-curve.ts`) stays web-only; the watch reads the fitted `cf` /
 * `wPrime` back off `tindeq_tags`.
 *
 * The model: the force curve is already the critical-force hyperbola
 * `F = CF + W'/t`, where W' is the finite work capacity above CF — already an
 * area, which is what makes it the natural basis for effort. Per rep, with
 * peak force P held for T seconds:
 *
 *   w_i = max(0, P - CF) * T   // kg·s of W' spent, the area above CF
 *   d_i = w_i / W'             // fraction of capacity, dimensionless
 *
 * This normalizes itself, so no arbitrary anchor is needed: a rep sitting
 * exactly ON the curve for its duration has P = CF + W'/T, so (P - CF)·T = W'
 * exactly, i.e. d = 1.0 — one "battery", a hang taken to failure. Session
 * load is L = Σ d_i over the session's reps, each rep against ITS OWN tag's
 * curve (a session can mix exercises).
 */

/// Every tunable of the model, in one place, so it can be retuned from real
/// sessions without hunting (same convention as `force-curve.ts`'s constants
/// and the watch's `Tunables.swift`).
export const RPE_DEPLETION = {
  /// Saturation scale of the load→RPE mapping, in batteries of W'. A
  /// starting value, deliberately tunable: RPE is bounded and the second
  /// battery hurts less than the first, so L0 sets how fast that saturates.
  /// L = 1 → 4.0, L = 2 → 6.0, L = 4 → 8.2, L = 8 → 9.6.
  l0: 2.5,
  /// Banked when NOT ONE rep of the session had a fitted curve — the same
  /// value the RPE prompts defaulted to before this was predicted at all.
  /// Never blocks the save; it just means "unknown", and the session is
  /// written `rpe_confirmed = false` exactly like a prediction is.
  fallbackRpe: 5,
} as const;

/// KNOWN LIMITATION (accepted for now, issue #280): reps at or below CF
/// contribute ~0, so a pure sub-CF endurance session under-predicts. That is
/// inherent to W'-depletion — the whole point of CF is that work below it is
/// sustainable. Revisit with real data rather than patching it with a second
/// arbitrary term.
export interface DepletionRep {
  /// Peak force of the rep (kg) — what the recording banks as `peak_kg`.
  peakKg: number;
  /// Hold duration in SECONDS (recordings store `duration_ms`).
  durationS: number;
  /// The rep's own tag's fitted curve. Null until that tag has enough long
  /// holds to fit one; a rep without a curve contributes nothing.
  cf: number | null;
  wPrime: number | null;
}

/// Fraction of W' spent by one rep, or null when its tag has no usable
/// curve (nothing fitted yet, or a degenerate W' ≤ 0 we can't divide by).
export function repDepletion(rep: DepletionRep): number | null {
  const { cf, wPrime } = rep;
  if (cf === null || wPrime === null || wPrime <= 0) return null;
  const durationS = Math.max(0, rep.durationS);
  return (Math.max(0, rep.peakKg - cf) * durationS) / wPrime;
}

/// Σ d_i over the session, or null when no rep had a curve to measure
/// against — an honestly absent load, not a zero one.
export function sessionDepletion(reps: DepletionRep[]): number | null {
  let load = 0;
  let measured = false;
  for (const rep of reps) {
    const d = repDepletion(rep);
    if (d === null) continue;
    measured = true;
    load += d;
  }
  return measured ? load : null;
}

/// Saturating load→RPE map: `RPE = 1 + 9·(1 - exp(-L/L0))`, rounded to 0.1
/// and clamped to [1, 10]. 0.1 matches `RPEQuantization.autoTracked` — these
/// are banked predictions, not user-entered half-points.
export function rpeForDepletion(load: number): number {
  const l = Math.max(0, load);
  const rpe = 1 + 9 * (1 - Math.exp(-l / RPE_DEPLETION.l0));
  return Math.round(Math.min(10, Math.max(1, rpe)) * 10) / 10;
}

export interface PredictedRpe {
  rpe: number;
  /// False when the session fell back (no rep had a curve). Either way the
  /// value is written with `rpe_confirmed = false` — nobody reviewed it.
  fromCurve: boolean;
  /// Σ d_i, null when nothing could be measured. Exposed for notes/debugging.
  load: number | null;
}

/// The one entry point both save paths use: never throws, never returns
/// nothing — a missing curve must never block logging a session.
export function predictSessionRpe(reps: DepletionRep[]): PredictedRpe {
  const load = sessionDepletion(reps);
  if (load === null) {
    return { rpe: RPE_DEPLETION.fallbackRpe, fromCurve: false, load: null };
  }
  return { rpe: rpeForDepletion(load), fromCurve: true, load };
}
