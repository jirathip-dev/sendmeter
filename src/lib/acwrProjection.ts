import { daysAhead, today } from "./dates";
import {
  ACUTE_SPAN_DAYS,
  CHRONIC_SPAN_DAYS,
  phaseAcwrFit,
  type EwmaLoadState,
  type PhaseAcwrFit,
} from "./metrics";

/// Decay factors of the two EWMAs behind ACWR, derived from the same spans
/// `ewmaLoadState` feeds `ewma()` — `ewma` uses lambda = 2/(span+1), so the
/// acute term keeps 0.75 of itself across a zero-load day and the chronic
/// term keeps 27/29 ≈ 0.931. Never restate these as literals: the whole point
/// of importing the spans is that a change to either window moves the ratio
/// and its projection together.
export const LAMBDA_ACUTE = 2 / (ACUTE_SPAN_DAYS + 1);
export const LAMBDA_CHRONIC = 2 / (CHRONIC_SPAN_DAYS + 1);

/// What a full rest day does to the ratio: acute decays faster than chronic,
/// so ACWR is multiplied by (1-λa)/(1-λc) ≈ 0.806 — a flat ~19.4%/day slide
/// that is INDEPENDENT of where you're starting from. From 1.20, two rest
/// days already put you under 0.80.
export const REST_DAY_ACWR_DECAY = (1 - LAMBDA_ACUTE) / (1 - LAMBDA_CHRONIC);

/// Seven days is the honest limit. The curve assumes zero training, and every
/// day the user deviates from that the tail past it is fiction — a 14- or
/// 28-day version would look more informative while being less true.
export const PROJECTION_DAYS = 7;

/// The RPE the "what it would take" suggestion is priced at. Session load is
/// `duration × RPE`, so any load splits into infinitely many (duration, RPE)
/// pairs; fixing one makes the number concrete. 6 is a moderate, repeatable
/// effort — it's the default RPE of most SESSION_TYPES and, unlike a hard 8,
/// it's a session someone can actually do on a day they weren't planning to
/// train. The card states the RPE it used rather than hiding it.
export const SUGGESTION_RPE = 6;

/// Sessions get logged in round durations, so the suggestion is quantized to
/// the nearest 5 minutes (and never below one, which would read as advice to
/// do a token session).
const DURATION_STEP_MIN = 5;

export interface ProjectedDay {
  /// Days from today. 0 is today's actual ratio, not a projection.
  dayOffset: number;
  date: string;
  acwr: number;
  /// Where this day sits against the PHASE band (not the universal risk
  /// zone). Null when there's no phase band to compare against.
  fit: PhaseAcwrFit | null;
}

/// A load target expressed as something you could actually do.
export interface LoadSuggestion {
  dayOffset: number;
  date: string;
  /// Exact AU needed on that day to land on the band floor.
  load: number;
  rpe: number;
  /// `load / rpe`, rounded to a loggable block — so `durationMin × rpe` is
  /// near, not exactly, `load`.
  durationMin: number;
}

export interface AcwrProjection {
  /// Today first (dayOffset 0, the real ratio), then one entry per projected
  /// day up to the horizon.
  days: ProjectedDay[];
  band: { low: number; high: number } | null;
  /// The first projected day (offset ≥ 1) that lands under the band floor —
  /// the actionable fact. Null when the curve stays in band all week, and
  /// also null when there's no band at all.
  fallsBelow: ProjectedDay | null;
  /// Only when today is ABOVE the band: the first day the decay brings the
  /// ratio back into it.
  entersBand: ProjectedDay | null;
  /// What it would take to stay in band on `fallsBelow` — assuming no
  /// training on any day before it. One day at a time; it is not a plan.
  keepInBand: LoadSuggestion | null;
}

/// One day of the EWMA recurrence forward: the same `v*λ + ema*(1-λ)` step
/// `ewma()` applies, with `load` as the day's value.
export function stepEwmaLoad(state: EwmaLoadState, load: number): EwmaLoadState {
  return {
    acute: load * LAMBDA_ACUTE + state.acute * (1 - LAMBDA_ACUTE),
    chronic: load * LAMBDA_CHRONIC + state.chronic * (1 - LAMBDA_CHRONIC),
  };
}

export function acwrOf(state: EwmaLoadState): number | null {
  return state.chronic > 0 ? state.acute / state.chronic : null;
}

/// Inverse of `stepEwmaLoad` + `acwrOf`: the load on the NEXT day that lands
/// the ratio exactly on `target`. Solving
///   (λa·L + (1-λa)·A) / (λc·L + (1-λc)·C) = R
/// gives L = ((1-λc)·R·C − (1-λa)·A) / (λa − λc·R).
///
/// A negative result is meaningful — it means even a rest day overshoots
/// `target` (you're above it) — so it's returned as-is and the caller
/// decides. Null means no load can get there: the denominator vanishes at
/// R = λa/λc ≈ 3.63 (past which more load moves the ratio the wrong way),
/// and a chronic term at or below zero has no ratio to aim at.
export function loadForRatio(state: EwmaLoadState, target: number): number | null {
  if (state.chronic <= 0) return null;
  const denominator = LAMBDA_ACUTE - LAMBDA_CHRONIC * target;
  if (denominator <= 0) return null;
  const numerator =
    (1 - LAMBDA_CHRONIC) * target * state.chronic - (1 - LAMBDA_ACUTE) * state.acute;
  return numerator / denominator;
}

/// Forward ACWR curve assuming ZERO training, against the current phase's
/// band. Deliberately not a schedule: it answers "what happens if I do
/// nothing", plus "what would one session on the day it drops out cost me" —
/// it does not say whether to train.
///
/// Null when there's nothing to project from: no session history
/// (`ewmaLoadState` returns null) or a chronic term at zero.
export function projectAcwr(
  state: EwmaLoadState | null,
  band: { low: number; high: number } | null,
  horizonDays: number = PROJECTION_DAYS,
): AcwrProjection | null {
  if (state === null) return null;
  const acwrToday = acwrOf(state);
  if (acwrToday === null) return null;

  const fitOf = (acwr: number): PhaseAcwrFit | null =>
    band === null ? null : phaseAcwrFit(acwr, { acwrLow: band.low, acwrHigh: band.high });

  const days: ProjectedDay[] = [
    { dayOffset: 0, date: today(), acwr: acwrToday, fit: fitOf(acwrToday) },
  ];
  // Kept alongside the ratios: the inverse needs the acute/chronic pair on
  // the day BEFORE the suggested session, which the ratio alone can't recover.
  const states: EwmaLoadState[] = [state];
  for (let i = 1; i <= horizonDays; i++) {
    const next = stepEwmaLoad(states[i - 1]!, 0);
    states.push(next);
    const acwr = acwrOf(next)!;
    days.push({ dayOffset: i, date: daysAhead(i), acwr, fit: fitOf(acwr) });
  }

  const projected = days.slice(1);
  const fallsBelow = band === null ? null : (projected.find((d) => d.fit === "below") ?? null);
  const entersBand =
    band === null || days[0]!.fit !== "above"
      ? null
      : (projected.find((d) => d.fit !== "above") ?? null);

  let keepInBand: LoadSuggestion | null = null;
  if (band !== null && fallsBelow !== null) {
    const load = loadForRatio(states[fallsBelow.dayOffset - 1]!, band.low);
    if (load !== null && load > 0) {
      keepInBand = {
        dayOffset: fallsBelow.dayOffset,
        date: fallsBelow.date,
        load,
        rpe: SUGGESTION_RPE,
        durationMin: Math.max(
          DURATION_STEP_MIN,
          Math.round(load / SUGGESTION_RPE / DURATION_STEP_MIN) * DURATION_STEP_MIN,
        ),
      };
    }
  }

  return { days, band, fallsBelow, entersBand, keepInBand };
}
