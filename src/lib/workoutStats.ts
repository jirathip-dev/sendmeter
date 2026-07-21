import type { WorkoutAttempt, WorkoutHrSample } from "../types";

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

/// Session intensity (SL-99): mean attempt effort score, or null if none of
/// the attempts carry one (older/phone workouts). Effort score already blends
/// HR + motion, so it reads as "how hard the climbs were".
export function meanEffort(attempts: WorkoutAttempt[]): number | null {
  const scores = attempts
    .map((a) => a.effortScore)
    .filter((s): s is number => s !== null);
  if (scores.length === 0) return null;
  return scores.reduce((a, b) => a + b, 0) / scores.length;
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
