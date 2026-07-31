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
 *
 * `isEffort` (#338): a rep's depletion can be known to be zero BY
 * CONSTRUCTION — independent of whether its tag has a fitted curve — when the
 * protocol that produced it is deliberately submaximal (currently only
 * Prehab, #325: targets 0.70×CF with a 0.30×maxF fallback when unfitted,
 * either way below CF). Web/phone-only field, never mirrored into
 * `RPEDepletion.swift` — the watch has no Prehab (or other non-effort)
 * protocol, so every watch-constructed rep is implicitly an effort rep, and
 * the "identical math / identical test vectors" contract still holds for
 * everything the watch actually exercises.
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
  /// Banked when NOT ONE EFFORT rep of the session could be measured against
  /// a fitted curve — i.e. effort whose depletion is genuinely UNKNOWN, not
  /// effort known to be minimal by design (see `DepletionRep.isEffort`,
  /// #338). The same value the RPE prompts defaulted to before this was
  /// predicted at all. Never blocks the save; it just means "unknown", and
  /// the session is written `rpe_confirmed = false` exactly like a
  /// prediction is.
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
  /// holds to fit one; a rep without a curve contributes nothing UNLESS
  /// `isEffort` is false (see below).
  cf: number | null;
  wPrime: number | null;
  /// Whether this rep spends measurable W′ (see
  /// `isDepletionEffortRecording`, zoneHistory.ts). False for a protocol
  /// known below CF BY CONSTRUCTION (currently only Prehab, #338) — its depletion is
  /// defined as zero regardless of whether cf/wPrime are populated, because
  /// we don't need to measure a hold we already know sits below CF. Only an
  /// effort rep's depletion depends on having a fitted curve at all. A
  /// future protocol with the same "known-minimal" property should also set
  /// this false, rather than relying on cf/wPrime happening to be absent.
  isEffort: boolean;
}

/// Fraction of W' spent by one rep. A non-effort rep (Prehab, #338) is
/// exactly 0 — its depletion is known by construction, not measured — even
/// when cf/wPrime are absent or when peakKg happens to sit above cf. An
/// effort rep with no usable curve (nothing fitted yet, or a degenerate
/// W' ≤ 0 we can't divide by) returns null — its depletion is genuinely
/// unmeasured, not zero.
export function repDepletion(rep: DepletionRep): number | null {
  if (!rep.isEffort) return 0;
  const { cf, wPrime } = rep;
  if (cf === null || wPrime === null || wPrime <= 0) return null;
  const durationS = Math.max(0, rep.durationS);
  return (Math.max(0, rep.peakKg - cf) * durationS) / wPrime;
}

/// Σ d_i over the session, or null when no rep contributed a measured value
/// — an honestly absent load, not a zero one. A non-effort rep (Prehab)
/// always contributes a measured 0, so it alone is enough to make a session
/// "measured" even with no fitted curve anywhere in it.
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
  /// False when the session fell back — every effort rep was unmeasured (no
  /// fitted curve) AND there was no non-effort rep to supply a known-zero
  /// measurement instead (#338). Either way the value is written with
  /// `rpe_confirmed = false` — nobody reviewed it.
  fromCurve: boolean;
  /// Σ d_i, null when nothing could be measured. Exposed for notes/debugging.
  load: number | null;
}

/// The one entry point both save paths use: never throws, never returns
/// nothing — a missing curve must never block logging a session. The
/// fallback branch below is for effort that could not be MEASURED, not for
/// effort already known to be minimal by construction — a rep whose protocol
/// guarantees near-zero depletion (Prehab, #338) must set `isEffort: false`
/// so `sessionDepletion` reads it as a measured zero instead of falling
/// through here.
export function predictSessionRpe(reps: DepletionRep[]): PredictedRpe {
  const load = sessionDepletion(reps);
  if (load === null) {
    return { rpe: RPE_DEPLETION.fallbackRpe, fromCurve: false, load: null };
  }
  return { rpe: rpeForDepletion(load), fromCurve: true, load };
}
