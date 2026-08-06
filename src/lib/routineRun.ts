import { ROUTINE_PREPARE_S, expandRoutine, routineDurationS } from "./routine";
import type { RoutineStep } from "../types";

/// Persisted state of an in-progress guided routine (SL-97). The routine
/// timer is wall-clock-derived (see RoutineFullscreen), so persisting these
/// fields is enough to resume exactly where it left off after a refresh
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
  /// Epoch ms of the last time RoutineFullscreen confirmed it was actually
  /// on-screen and ticking — a heartbeat throttled to ~HEARTBEAT_MS, stamped
  /// on every write while running (#483 review F1/F3/F5). This is the one
  /// field that can tell "present until (near) the end, then the WebView was
  /// reclaimed/suspended" apart from "abandoned minutes ago and left
  /// dangling" — wall-clock `elapsedS` alone reads identically for both once
  /// it has run past the routine's total. See `classifyElapsed` /
  /// `resolveRoutineResume` below for how it's used.
  lastSeenMs: number;
}

const KEY = "sendmeter:routine-run";

/// How often RoutineFullscreen stamps a fresh `lastSeenMs` heartbeat into the
/// persisted record while genuinely ticking (ms) — #483 review F1/F3/F5.
export const HEARTBEAT_MS = 5_000;

/// How stale a run's `lastSeenMs` can be (seconds) before wall-clock-since-
/// start is no longer trusted as "still in progress" (#483 review F1/F3/F5).
/// Generous relative to HEARTBEAT_MS (6x) to tolerate a couple of missed or
/// throttled ticks, but short enough to catch a genuinely reclaimed or
/// suspended WebView promptly rather than resuming into dead time.
export const STALE_GAP_S = 30;

/// How close a "confirmed" elapsed has to be to the routine's own total to
/// count as a completed routine rather than a partial one, once wall clock
/// alone can no longer be trusted (#483 review F1) — a couple of heartbeat
/// intervals' worth of slack for the last tick before a reclaim/suspend.
const PRESENCE_MARGIN_S = 10;

/// Elapsed routine seconds — identical formula to RoutineFullscreen's live
/// derivation, extracted so it can be unit-tested and reused at exit time.
/// Includes `skippedS`: this is a *position in the routine's timeline*
/// (drives segment index / the done flag / resume gating), not a duration to
/// log — see `realElapsedS` for the real-time counterpart used for logging
/// (#483 review F4).
export function elapsedS(s: RoutineRunState, nowMs: number): number {
  return ((s.pausedAtMs ?? nowMs) - s.startedMs - s.pausedTotalMs) / 1000 + s.skippedS;
}

/// Real seconds actually spent on the routine — same as `elapsedS` but
/// WITHOUT skipped-segment credit (#483 review F4). `elapsedS` legitimately
/// includes `skippedS` so Skip can fast-forward the routine's position and
/// reach "done" sooner; but a *logged duration* must reflect real time
/// worked, not fast-forwarded time — a 45-minute routine skipped through in
/// 30 real seconds must log ~1 minute, not the routine's nominal 45.
export function realElapsedS(s: RoutineRunState, nowMs: number): number {
  return ((s.pausedAtMs ?? nowMs) - s.startedMs - s.pausedTotalMs) / 1000;
}

/// A run is worth logging as a (partial) session only past a minute — briefer
/// runs are accidental opens and are discarded silently.
export function shouldLog(elapsed: number): boolean {
  return elapsed >= 60;
}

/// Whole minutes for the logged session, clamped to the `sessions` table's
/// `duration_min` check (1..600, see supabase/migrations) — this is the last
/// line of defence and must hold no matter what elapsed value a caller passes
/// in, including non-finite values (#483: an unbounded or NaN value here is
/// what turns a stale/abandoned run into a DB-rejected insert, or a rejected
/// insert with an opaque error, instead of a merely-wrong one).
export function partialMinutes(elapsed: number): number {
  // NaN fails every comparison, so it slips through Math.max/Math.min
  // unclamped (`Math.max(1, NaN) === NaN`) — the one input this clamp didn't
  // actually clamp (#483 review F6). Infinity/-Infinity are already handled
  // correctly by the Math.min/Math.max clamp below and don't need this guard.
  if (Number.isNaN(elapsed)) return 1;
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
/// total duration was not "in progress" when it was left — it was abandoned,
/// as far as wall clock alone can tell (#483). This must read `s`'s own
/// frozen/live elapsed via `elapsedS`, which already resolves a paused run to
/// its frozen elapsed regardless of how much real time has passed since — a
/// genuinely paused run is never "abandoned" by this check as long as its
/// frozen elapsed is still under total. NOTE: on its own this is necessary
/// but not sufficient to decide what to do — it cannot distinguish "abandoned
/// minutes ago" from "finished, then the WebView was reclaimed right at the
/// end" (both read `elapsedS >= totalS`); `resolveRoutineResume` combines it
/// with the `lastSeenMs` heartbeat to tell those apart (#483 review F1/F5).
export function isAbandoned(s: RoutineRunState, totalS: number, nowMs: number): boolean {
  return elapsedS(s, nowMs) >= totalS;
}

/// Outcome of classifying a *confirmed* ("seen") elapsed value against the
/// routine's total, once wall clock alone can no longer be trusted (#483
/// review F1/F3/F5): close enough to the total counts as a completed
/// routine; short of it but still worth logging (`shouldLog`'s existing ≥60s
/// bar) is a partial; anything less is discarded. The caller MUST surface a
/// "discarded" outcome visibly — never silently. Today's silent discard
/// (nothing logged, no toast, no banner) is worse than either of the other
/// two outcomes: it destroys real training with no trace of why.
export type RoutineLogOutcome =
  | { kind: "completed"; durationMin: number }
  | { kind: "partial"; durationMin: number }
  | { kind: "discarded" };

export function classifyElapsed(seenElapsed: number, totalS: number): RoutineLogOutcome {
  if (seenElapsed >= totalS - PRESENCE_MARGIN_S) {
    return { kind: "completed", durationMin: loggedMinutes(seenElapsed, totalS) };
  }
  if (shouldLog(seenElapsed)) {
    return { kind: "partial", durationMin: partialMinutes(seenElapsed) };
  }
  return { kind: "discarded" };
}

export type RoutineResumeOutcome =
  | { kind: "none" }
  | { kind: "resume"; presetId: string }
  | (RoutineLogOutcome & { presetId: string });

/// Decides what a persisted run (SL-97) should do on mount: auto-resume, log
/// as completed/partial, or be discarded — always visibly (#483).
///
/// Mirrors RoutineCard's mount effect exactly — call this from there rather
/// than re-deriving the decision.
///
/// A paused run is frozen and fully trusted regardless of staleness — pause
/// is an explicit, deliberate action (a paused run must resume correctly
/// even read back hours later). A running (unpaused) run is only trusted as
/// "still in progress" while its `lastSeenMs` heartbeat is recent
/// (`STALE_GAP_S`); past that, or once wall clock says it's run past its own
/// total, the decision falls back to `classifyElapsed` using what the
/// heartbeat actually confirmed — never raw wall clock across an unobserved
/// gap, which is what let a stale run resume-and-immediately-finish with a
/// fabricated duration (#483 review F5).
export function resolveRoutineResume(
  run: RoutineRunState | null,
  presets: { id: string; steps: RoutineStep[] }[],
  nowMs: number,
): RoutineResumeOutcome {
  if (!run) return { kind: "none" };
  const preset = presets.find((p) => p.id === run.presetId);
  if (!preset) return { kind: "none" };
  const totalS = routineDurationS(expandRoutine(preset.steps, { prepareS: ROUTINE_PREPARE_S }));

  if (run.pausedAtMs !== null) {
    if (!isAbandoned(run, totalS, nowMs)) return { kind: "resume", presetId: run.presetId };
    return { ...classifyElapsed(realElapsedS(run, nowMs), totalS), presetId: run.presetId };
  }

  const gapS = (nowMs - run.lastSeenMs) / 1000;
  if (gapS <= STALE_GAP_S && !isAbandoned(run, totalS, nowMs)) {
    return { kind: "resume", presetId: run.presetId };
  }
  return { ...classifyElapsed(realElapsedS(run, run.lastSeenMs), totalS), presetId: run.presetId };
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
        // A record written before this field existed (or otherwise missing
        // it) has no heartbeat history to distrust — default to "just seen"
        // rather than "ancient", so a genuinely in-progress legacy run isn't
        // misclassified as stale on the one reload that crosses the deploy
        // that introduced this field (#483 review F1/F3/F5).
        lastSeenMs: typeof p.lastSeenMs === "number" ? p.lastSeenMs : Date.now(),
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
