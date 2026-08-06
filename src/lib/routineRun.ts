import { ROUTINE_PREPARE_S, expandRoutine, routineDurationS } from "./routine";
import type { RoutineStep } from "../types";

/// Persisted state of an in-progress guided routine (SL-97). The routine
/// timer is wall-clock-derived (see RoutineFullscreen), so persisting these
/// five fields is enough to resume exactly where it left off after a refresh
/// or relaunch — the clock keeps ticking against `startedMs`. Mirrors the
/// phone-workout write-through persistence (src/hooks/usePhoneWorkout.ts).
export interface RoutineRunState {
  presetId: string;
  startedMs: number;
  skippedS: number;
  /// Epoch ms when Pause was hit, or null while running.
  pausedAtMs: number | null;
  /// Accumulated paused time (ms) across prior pause/resume cycles.
  pausedTotalMs: number;
}

const KEY = "sendmeter:routine-run";

/// Elapsed routine seconds — identical formula to RoutineFullscreen's live
/// derivation, extracted so it can be unit-tested and reused at exit time.
export function elapsedS(s: RoutineRunState, nowMs: number): number {
  return ((s.pausedAtMs ?? nowMs) - s.startedMs - s.pausedTotalMs) / 1000 + s.skippedS;
}

/// A run is worth logging as a (partial) session only past a minute — briefer
/// runs are accidental opens and are discarded silently.
export function shouldLog(elapsed: number): boolean {
  return elapsed >= 60;
}

/// Whole minutes for the logged session, clamped to the `sessions` table's
/// `duration_min` check (1..600, see supabase/migrations) — this is the last
/// line of defence and must hold no matter what elapsed value a caller passes
/// in (#483: an unbounded value here is what turns a stale/abandoned run into
/// a DB-rejected insert instead of a merely-wrong one).
export function partialMinutes(elapsed: number): number {
  return Math.min(600, Math.max(1, Math.round(elapsed / 60)));
}

/// Minutes to log for a *completed* routine, capped at what the routine could
/// actually have taken (`totalS`, its own expanded duration) rather than raw
/// wall clock (#483). Wall-clock elapsed since `startedMs` can run far past
/// the routine's total — a resumed-then-abandoned run, or a live run left
/// mounted and unattended past completion — and must not be logged as-is.
export function loggedMinutes(elapsed: number, totalS: number): number {
  return partialMinutes(Math.min(elapsed, totalS));
}

/// A persisted run whose wall-clock elapsed already meets or exceeds its own
/// total duration was not "in progress" when it was left — it was abandoned
/// (#483). This must read `s`'s own frozen/live elapsed via `elapsedS`, which
/// already resolves a paused run to its frozen elapsed regardless of how much
/// real time has passed since — a genuinely paused run is never "abandoned"
/// by this check as long as its frozen elapsed is still under total.
export function isAbandoned(s: RoutineRunState, totalS: number, nowMs: number): boolean {
  return elapsedS(s, nowMs) >= totalS;
}

/// Decides whether a persisted run (SL-97) should auto-resume on mount, or be
/// discarded as abandoned (#483). Mirrors RoutineCard's mount effect exactly
/// — call this from there rather than re-deriving the decision, so tests
/// exercise the actual production path.
export function resolveRoutineResume(
  run: RoutineRunState | null,
  presets: { id: string; steps: RoutineStep[] }[],
  nowMs: number,
): string | null {
  if (!run) return null;
  const preset = presets.find((p) => p.id === run.presetId);
  if (!preset) return null;
  const totalS = routineDurationS(expandRoutine(preset.steps, { prepareS: ROUTINE_PREPARE_S }));
  if (isAbandoned(run, totalS, nowMs)) return null;
  return run.presetId;
}

export function loadRoutineRun(): RoutineRunState | null {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return null;
    const p = JSON.parse(raw) as Partial<RoutineRunState>;
    if (typeof p.presetId === "string" && typeof p.startedMs === "number") {
      return {
        presetId: p.presetId,
        startedMs: p.startedMs,
        skippedS: typeof p.skippedS === "number" ? p.skippedS : 0,
        pausedAtMs: typeof p.pausedAtMs === "number" ? p.pausedAtMs : null,
        pausedTotalMs: typeof p.pausedTotalMs === "number" ? p.pausedTotalMs : 0,
      };
    }
    return null;
  } catch {
    return null;
  }
}

export function saveRoutineRun(s: RoutineRunState): void {
  try {
    localStorage.setItem(KEY, JSON.stringify(s));
  } catch {
    /* quota / disabled storage — persistence is best-effort */
  }
}

export function clearRoutineRun(): void {
  try {
    localStorage.removeItem(KEY);
  } catch {
    /* ignore */
  }
}
