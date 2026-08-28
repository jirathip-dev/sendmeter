import type {
  AcwrData,
  AcwrStatus,
  HealthMetric,
  Phase,
  PhaseId,
  PhasePeriod,
  Session,
  TindeqRecordingMeta,
  WeeklyLoad,
} from "./types.js";
import { blockAge, daysAgo, today, type BlockAge } from "./dates.js";

export function getACWRStatus(acwr: number | null): AcwrStatus {
  // Colors are CSS-var strings — applied via inline style, they track the
  // theme's health scale (cool = good) and light/dark automatically.
  if (acwr === null) return { label: "No data", color: "var(--ink-muted)" };
  if (acwr < 0.7) return { label: "Under-training", color: "var(--primary)" };
  if (acwr <= 0.8) return { label: "Low", color: "var(--info)" };
  if (acwr <= 1.3) return { label: "Optimal", color: "var(--success)" };
  if (acwr <= 1.5) return { label: "Caution", color: "var(--warning)" };
  return { label: "Danger", color: "var(--danger)" };
}

// Track background for the ACWR range bar in Dashboard.tsx. Band edges match
// getACWRStatus's thresholds exactly (0.8 / 1.3 / 1.5 on a 0-2 scale → 40% /
// 65% / 75%) — the marker dot shares the same `(acwr / 2) * 100%` mapping, so
// the dot always lands in the band that names its own status (issue #189:
// these used to disagree, e.g. a 1.37 dot rendering past the "1.5"
// gridline). Stops are placed symmetrically around each true threshold so
// the 50/50 blend midpoint lands exactly on the original band edge (issue
// #213: a previous edit collapsed every transition into a same-position
// hard stop, losing the gradient blend entirely):
//   - 0.8 -> 40%: blend spans 32%-48%, midpoint 40%
//   - 1.3 -> 65%: blend spans 58%-72%, midpoint 65%
//   - 1.5 -> 75%: blend spans 72%-78%, midpoint 75%
// Pure --info 0-32%, pure --success 48-58%, pure --warning at 72% (a single
// point, still a visible color moment), pure --danger 78-100%.
export const ACWR_TRACK_GRADIENT =
  "linear-gradient(to right, var(--info) 0%, var(--info) 32%, var(--success) 48%, var(--success) 58%, var(--warning) 72%, var(--danger) 78%, var(--danger) 100%)";

export type PhaseAcwrFit = "below" | "on" | "above";

/// Whether the current ACWR sits below / within / above the target band the
/// current phase is documented to aim for (Phase.acwrLow/acwrHigh). This is
/// deliberately separate from getACWRStatus: that returns the *universal*
/// injury-risk zone (independent of phase), whereas this says whether your
/// load matches your phase's *intent* — a "power" phase aims lower/hotter
/// than "capacity", so the same ratio reads differently against each.
export function phaseAcwrFit(
  acwr: number | null,
  phase: Pick<Phase, "acwrLow" | "acwrHigh"> | undefined,
): PhaseAcwrFit | null {
  if (acwr === null || !phase) return null;
  if (acwr < phase.acwrLow) return "below";
  if (acwr > phase.acwrHigh) return "above";
  return "on";
}

/// The current phase's open `phase_periods` row's start date, phase-aware —
/// guards against a stale `phasePeriods` snapshot that still belongs to a
/// phase just switched away from. During a phase switch, `currentPhase` and
/// `phaseStartDate` flip optimistically (synchronously) while `phasePeriods`
/// only refreshes after the async `switchPhase` call resolves; naively taking
/// "whichever period is open" during that window returns the OLD phase's
/// period, producing a bogus transient "Day N" (see issue #170). Falls back
/// to `phaseStartDate` — which is set to today() at the same instant
/// `currentPhase` flips — whenever no open period matches `currentPhase`,
/// including that transient window.
export function currentPeriodStart(
  phasePeriods: Pick<PhasePeriod, "phase" | "startedOn" | "endedOn">[],
  currentPhase: PhaseId,
  phaseStartDate: string,
): string {
  return (
    phasePeriods.find((p) => p.endedOn === null && p.phase === currentPhase)
      ?.startedOn ?? phaseStartDate
  );
}

/// The one composition Home and the Training phases sheet both call for the
/// user-facing block-age display (issue #544) — `currentPeriodStart` feeding
/// `blockAge`, hoisted here so the two screens can't drift onto different
/// start dates or different day math by editing one call site and not the
/// other (they used to: the Home strip read `phaseStartFromHistory()`'s
/// recent-session-streak start instead of this canonical one). Deliberately
/// has NO session parameter — the whole point of #544 is that session
/// history must never be able to feed the displayed block age.
export function phaseBlockAge(
  phasePeriods: Pick<PhasePeriod, "phase" | "startedOn" | "endedOn">[],
  currentPhase: PhaseId,
  phaseStartDate: string,
  referenceDate: string,
): BlockAge | null {
  return blockAge(currentPeriodStart(phasePeriods, currentPhase, phaseStartDate), referenceDate);
}

// "Low" readiness mirrors the "recover" zone floor already drawn as a
// gridline on ReadinessCard and colored var(--danger) — see
// RecoveryTunables.zoneRecoverBelow in sendlog-health-core (kept in sync by
// hand; the score/zone pair is computed server-side and both land in
// health_metrics). Reusing it means this suggestion agrees with what the
// user already sees as "red" rather than inventing a second threshold.
const LOW_READINESS_THRESHOLD = 40;

// A single rough night is noise; a multi-day trend is a signal worth acting
// on. 3 consecutive low days is the shortest window that reads as a trend
// rather than a blip — short enough to still be timely mid-phase.
const LOW_READINESS_STREAK_DAYS = 3;

// Phases whose whole intent is pushing load/intensity — the only phases a
// "step back" suggestion is meaningful for. Capacity is already the
// step-back phase (nothing to suggest); execution is taper/comp-focused,
// where backing off defeats the point, so it's deliberately out of scope.
const STEP_BACK_PHASES: ReadonlySet<PhaseId> = new Set(["power", "strength"]);

export interface PhaseStepBackSuggestion {
  /// Whether to show the soft nudge right now.
  suggested: boolean;
  /// Consecutive low-readiness days counted back from today (0 if the
  /// streak is broken, insufficient, or the phase doesn't apply). Also
  /// doubles as the per-streak key the UI persists a dismissal under, so a
  /// fresh streak (post-recovery relapse) shows the suggestion again.
  streakDays: number;
}

/// Recovery-adjusted phase suggestion (SL-23): softly nudge toward capacity
/// when readiness has trended low for several days while training in a
/// power/strength phase — closing the loop between the two signals
/// (readiness, phase) that today are only ever shown in parallel.
///
/// Conservative by construction: a day with no reading at all (missing from
/// `readinessHistory`, e.g. watch not worn) breaks the streak exactly like a
/// day with a good score would — sparse history never *manufactures* a
/// suggestion, it just fails to confirm one. The streak walks backward from
/// today via `daysAgo`, so it only counts an *unbroken run ending today*;
/// three low days a week ago don't linger and trigger it now.
///
/// Clears on its own next render once either input moves: readiness recovery
/// (today's score is missing or back at/above the threshold) resets the walk
/// to 0 immediately, and switching to a non-power/strength phase (including
/// the capacity step-back this suggests) short-circuits to `suggested: false`
/// before the readiness streak is even walked.
export function suggestPhaseStepBack(
  readinessHistory: Pick<HealthMetric, "date" | "readiness">[],
  currentPhase: PhaseId,
): PhaseStepBackSuggestion {
  if (!STEP_BACK_PHASES.has(currentPhase)) return { suggested: false, streakDays: 0 };

  const byDate = new Map(readinessHistory.map((m) => [m.date, m.readiness]));
  let streak = 0;
  for (let i = 0; ; i++) {
    const readiness = byDate.get(daysAgo(i));
    if (readiness == null || readiness >= LOW_READINESS_THRESHOLD) break;
    streak++;
  }
  return { suggested: streak >= LOW_READINESS_STREAK_DAYS, streakDays: streak };
}

const EWMA_LOOKBACK_DAYS = 90;

/// The two EWMA windows behind the acute:chronic ratio. Exported so the
/// forward projection (`acwrProjection.ts`) derives its decay constants from
/// the same spans rather than restating them — a projection that disagrees
/// with the ratio it extends is worse than no projection.
export const ACUTE_SPAN_DAYS = 7;
export const CHRONIC_SPAN_DAYS = 28;

/// Exponentially-weighted moving average over a daily series, null-aware:
/// leading nulls stay null (nothing to average yet — the EMA seeds at the
/// first non-null value), and interior nulls carry the previous EMA forward
/// unchanged (a missing day is "no new information", not a zero). Used for
/// the short/long trend overlays on the recovery-inputs chart; ewmaAcwr
/// below shares the same recurrence on a dense (non-null) series.
export function ewma(
  values: (number | null)[],
  span: number,
): (number | null)[] {
  const lambda = 2 / (span + 1);
  const out: (number | null)[] = new Array<number | null>(values.length);
  let ema: number | null = null;
  for (let i = 0; i < values.length; i++) {
    const v = values[i] ?? null;
    if (v !== null) ema = ema === null ? v : v * lambda + ema * (1 - lambda);
    out[i] = ema;
  }
  return out;
}

/// The pair of exponentially-weighted load averages the ACWR ratio is built
/// from, as of today. Both are in the same AU units as `Session.load`.
export interface EwmaLoadState {
  acute: number;
  chronic: number;
}

/// The acute/chronic EWMA terms behind `ewmaAcwr` — the ratio's numerator and
/// denominator, kept separately so they can be stepped forward day by day
/// (`acwrProjection.ts`). Null when there is no load at all in the lookback
/// window (nothing to average).
export function ewmaLoadState(sessions: Session[]): EwmaLoadState | null {
  const loadByDate = new Map<string, number>();
  for (const s of sessions) {
    loadByDate.set(s.date, (loadByDate.get(s.date) ?? 0) + s.load);
  }
  const dailyLoads: number[] = [];
  for (let i = EWMA_LOOKBACK_DAYS - 1; i >= 0; i--) {
    dailyLoads.push(loadByDate.get(daysAgo(i)) ?? 0);
  }
  if (dailyLoads.every((v) => v === 0)) return null;

  // Seeding: ewma() seeds at the series' first value, so prepending the
  // window mean reproduces the original mean-seeded recurrence exactly.
  const seed = dailyLoads.reduce((s, v) => s + v, 0) / dailyLoads.length;
  const series = [seed, ...dailyLoads];
  return {
    acute: ewma(series, ACUTE_SPAN_DAYS)[series.length - 1]!,
    chronic: ewma(series, CHRONIC_SPAN_DAYS)[series.length - 1]!,
  };
}

/// Exponentially-weighted acute:chronic ratio (Williams et al. 2016), which
/// the literature now favors over the plain rolling-average ratio: it
/// weights recent days more heavily and avoids "mathematical coupling"
/// (the acute window being a literal subset of the chronic window), giving
/// a more sensitive, more responsive signal. Both EWMAs are seeded with the
/// window's mean load (not a raw first-day value) to shrink the start-up
/// bias inherent to any EWMA — by 90 daily steps the seed's influence on
/// the chronic term has decayed to under 1%.
function ewmaAcwr(sessions: Session[]): number | null {
  const state = ewmaLoadState(sessions);
  if (state === null) return null;
  return state.chronic > 0 ? state.acute / state.chronic : null;
}

export function computeAcwr(sessions: Session[]): AcwrData {
  // acute/chronic stay simple rolling sums — they're shown as-is on the
  // Load card ("Acute 7d", "Chronic avg") where a plain total is the
  // intuitive read. Only the acwr ratio itself (and its risk zone) uses
  // the more sensitive EWMA method.
  const acute = sessions
    .filter((s) => s.date >= daysAgo(6) && s.date <= today())
    .reduce((sum, s) => sum + s.load, 0);
  const chronic =
    sessions
      .filter((s) => s.date >= daysAgo(27) && s.date <= today())
      .reduce((sum, s) => sum + s.load, 0) / 4;
  return { acute, chronic, acwr: ewmaAcwr(sessions) };
}

export interface TindeqStats {
  bestPeak: number;
  lastPeak: number;
  avg30d: number | null;
  delta: number | null; // lastPeak - avg30d
}

export function computeTindeqStats(
  recordings: TindeqRecordingMeta[],
): TindeqStats | null {
  const measured = recordings.filter((r): r is TindeqRecordingMeta & { peakKg: number; avgKg: number } => r.source !== "manual" && r.peakKg != null && r.avgKg != null);
  if (measured.length < 2) return null;
  const sorted = [...measured].sort((a, b) =>
    a.recordedAt.localeCompare(b.recordedAt),
  );
  const last = sorted[sorted.length - 1]!;
  const bestPeak = Math.max(...sorted.map((r) => r.peakKg));
  const cutoff = Date.now() - 30 * 86400000;
  const window = sorted.filter(
    (r) => Date.parse(r.recordedAt) >= cutoff && r.id !== last.id,
  );
  const avg30d = window.length
    ? window.reduce((s, r) => s + r.peakKg, 0) / window.length
    : null;
  return {
    bestPeak,
    lastPeak: last.peakKg,
    avg30d,
    delta: avg30d === null ? null : last.peakKg - avg30d,
  };
}

export function computeWeeklyLoads(sessions: Session[]): WeeklyLoad[] {
  return [3, 2, 1, 0].map((wb) => {
    const start = daysAgo(wb * 7 + 6);
    const end = daysAgo(wb * 7);
    const total = sessions
      .filter((s) => s.date >= start && s.date <= end)
      .reduce((sum, s) => sum + s.load, 0);
    return { label: wb === 0 ? "Now" : `${wb}w`, total };
  });
}
