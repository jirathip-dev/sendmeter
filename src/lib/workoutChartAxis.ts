import type { ChartPadding } from "../hooks/useSvgScale";
import type { WorkoutAttempt, WorkoutHrSample } from "../types";

/// Shared x-axis maths for the charts stacked inside a workout's history
/// detail (HR trace + attempt effort). Both charts must plot the *same*
/// seconds-since-workout-start domain into the *same* pixel plot area, or a
/// given x reads as a different instant in each (SL-183).

/// Padding every workout-detail chart uses. `left` is the y-label gutter —
/// the usual cause of two stacked charts starting their plot area at
/// different x — so it's a shared constant rather than a per-chart one.
export const WORKOUT_CHART_PAD: ChartPadding = {
  top: 6,
  right: 6,
  bottom: 14,
  left: 26,
};

/// One attempt placed on the workout timeline, in trace seconds.
export interface AttemptWindow {
  start: number;
  end: number;
  manual: boolean;
}

/// Seconds between two ISO timestamps (negative if `iso` precedes `from`).
export function secondsSince(from: string, iso: string): number {
  return (new Date(iso).getTime() - new Date(from).getTime()) / 1000;
}

/// Attempt start/end in seconds from the workout start.
export function attemptWindows(
  startedAt: string,
  attempts: WorkoutAttempt[],
): AttemptWindow[] {
  return attempts.map((a) => {
    const start = secondsSince(startedAt, a.startedAt);
    return { start, end: start + a.durationS, manual: a.source === "manual" };
  });
}

/// The shared x domain, [0, tMax], in seconds from the workout start.
///
/// Driven by the *data* — the end of the HR trace and the last attempt —
/// rather than by `endedAt`, so a workout left running long after the last
/// climb doesn't squash the trace into a sliver. `endedAt` is only the
/// fallback when there is neither a trace nor an attempt. Always ≥ 1 so the
/// scale never collapses to a zero-width domain.
export function workoutTimeMaxS(input: {
  startedAt: string;
  endedAt: string;
  attempts: WorkoutAttempt[];
  samples: WorkoutHrSample[] | null;
}): number {
  const { startedAt, endedAt, attempts, samples } = input;
  const traceEnd = samples?.length ? samples[samples.length - 1]!.t : 0;
  const attemptEnd = attemptWindows(startedAt, attempts).reduce(
    (max, w) => Math.max(max, w.end),
    0,
  );
  const dataEnd = Math.max(traceEnd, attemptEnd);
  if (dataEnd > 0) return dataEnd;
  return Math.max(1, secondsSince(startedAt, endedAt));
}

/// Tick positions along the shared time axis. Same values for every chart in
/// the stack, so the ticks land on identical pixels.
export function workoutXTicks(tMax: number): number[] {
  return [0, tMax / 2, tMax];
}

/// m:ss for an axis label / tooltip.
export function fmtMinSec(tS: number): string {
  const m = Math.floor(tS / 60);
  const s = Math.round(tS % 60);
  return `${m}:${String(s).padStart(2, "0")}`;
}
