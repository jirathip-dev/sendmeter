import type { WorkoutAttempt, WorkoutHrSample } from "../types";

/// Per-workout summary stats (SL-85) — pure and testable.

/// Mean attempt (climb) duration and mean rest between consecutive attempts.
export function climbRestStats(attempts: WorkoutAttempt[]): {
  avgClimbS: number | null;
  avgRestS: number | null;
} {
  if (attempts.length === 0) return { avgClimbS: null, avgRestS: null };
  const avgClimbS =
    attempts.reduce((s, a) => s + a.durationS, 0) / attempts.length;
  if (attempts.length < 2) return { avgClimbS, avgRestS: null };
  const rests: number[] = [];
  for (let i = 1; i < attempts.length; i++) {
    const prevEnd =
      Date.parse(attempts[i - 1]!.startedAt) + attempts[i - 1]!.durationS * 1000;
    const gap = (Date.parse(attempts[i]!.startedAt) - prevEnd) / 1000;
    if (gap > 0) rests.push(gap);
  }
  return {
    avgClimbS,
    avgRestS: rests.length ? rests.reduce((a, b) => a + b, 0) / rests.length : null,
  };
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
