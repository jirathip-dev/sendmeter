import type { Session, WorkoutAttempt, WorkoutHrSample } from "../types";

/// Per-workout summary stats (SL-85 / SL-99) — pure and testable.

/// Positive rest gaps (seconds) between consecutive attempts. Overlapping /
/// out-of-order attempts (gap ≤ 0) are skipped.
function restGaps(attempts: WorkoutAttempt[]): number[] {
  const gaps: number[] = [];
  for (let i = 1; i < attempts.length; i++) {
    const prevEnd =
      Date.parse(attempts[i - 1]!.startedAt) + attempts[i - 1]!.durationS * 1000;
    const gap = (Date.parse(attempts[i]!.startedAt) - prevEnd) / 1000;
    if (gap > 0) gaps.push(gap);
  }
  return gaps;
}

/// Work-to-rest ratio (SL-99): total climbing seconds ÷ total rest seconds.
/// Higher = a denser session (more time on the wall per second of rest).
/// Null with < 2 attempts or no measurable rest.
export function workRestRatio(attempts: WorkoutAttempt[]): number | null {
  if (attempts.length < 2) return null;
  const work = attempts.reduce((s, a) => s + a.durationS, 0);
  const rest = restGaps(attempts).reduce((a, b) => a + b, 0);
  if (rest <= 0) return null;
  return work / rest;
}

/// Mean HR recovery after attempts: HR at the attempt's end minus the LOWEST
/// HR reached within the next `windowS` seconds — how fast the heart comes
/// down between climbs. Trace `t` is seconds from workout start.
export function hrRecoveryBpm(
  trace: WorkoutHrSample[],
  workoutStartedAt: string,
  attempts: WorkoutAttempt[],
  windowS = 60,
): number | null {
  const startMs = Date.parse(workoutStartedAt);
  const hrAtOrAfter = (t: number): number | null => {
    // First sample with hr at or (within 10s) after t.
    for (const s of trace) {
      if (s.t >= t && s.t <= t + 10 && s.hr !== null) return s.hr;
    }
    return null;
  };
  const drops: number[] = [];
  for (const a of attempts) {
    const endT = (Date.parse(a.startedAt) - startMs) / 1000 + a.durationS;
    const hrEnd = hrAtOrAfter(endT);
    if (hrEnd === null) continue;
    let low: number | null = null;
    for (const s of trace) {
      if (s.t > endT && s.t <= endT + windowS && s.hr !== null) {
        if (low === null || s.hr < low) low = s.hr;
      }
    }
    if (low !== null && hrEnd - low > 0) drops.push(hrEnd - low);
  }
  return drops.length
    ? drops.reduce((a, b) => a + b, 0) / drops.length
    : null;
}

/// Distinct-day RPE trend for the Workout tab's recent-training chart
/// (#108): unlike the metrics above (which only cover watch/phone-tracked
/// climbs that have attempts), this reads straight off every logged
/// session's `rpe` — so a session saved via "Log a past workout" (the
/// manual flow: a `sessions` row only, no matching `climb_workouts` row)
/// still shows up. Buckets by the session's own `date` string (already a
/// local YYYY-MM-DD — see dates.ts) via plain string comparison, never
/// parsed into a `Date`, so there's no UTC/local conversion to drop a day
/// near midnight. Same-day sessions average their RPE. Returns the most
/// recent `days` distinct dates that have a session, oldest → newest (so a
/// left-to-right bar trend reads as time moving forward).
///
/// `confirmed` (issue #114) is false for a day if ANY session contributing
/// to its average is an unreviewed phone auto-save still sitting at the
/// hardcoded default RPE — the chart mutes that bar rather than rendering it
/// indistinguishably from a user-confirmed value.
export function recentDailyRpe(
  sessions: Pick<Session, "date" | "rpe" | "rpeConfirmed">[],
  days: number,
): { date: string; rpe: number; confirmed: boolean }[] {
  const byDate = new Map<string, { sum: number; n: number; confirmed: boolean }>();
  for (const s of sessions) {
    const e = byDate.get(s.date);
    if (e) {
      e.sum += s.rpe;
      e.n += 1;
      if (s.rpeConfirmed === false) e.confirmed = false;
    } else {
      byDate.set(s.date, { sum: s.rpe, n: 1, confirmed: s.rpeConfirmed !== false });
    }
  }
  return [...byDate.entries()]
    .sort((a, b) => b[0].localeCompare(a[0]))
    .slice(0, days)
    .reverse()
    .map(([date, e]) => ({ date, rpe: e.sum / e.n, confirmed: e.confirmed }));
}
