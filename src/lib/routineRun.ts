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

/// Whole minutes for the logged session (≥1), matching the natural-finish path.
export function partialMinutes(elapsed: number): number {
  return Math.max(1, Math.round(elapsed / 60));
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
