import type { ProtocolSegment } from "./protocol";
import type { TindeqSide } from "../types";
import type { HandsFreeForceConfig } from "./handsFreeForce";
import { DEFAULT_HANDS_FREE_FORCE_CONFIG } from "./handsFreeForce";

export interface AdaptiveStaticHold {
  segmentIndex: number;
  set: number;
  rep: number;
  side: TindeqSide;
  durationMs: number;
  recoveryMs: number;
}

export type AdaptiveStaticState =
  | { phase: "armed"; holdIndex: number; aboveSinceMs: number | null; lastMs: number }
  | { phase: "hold"; holdIndex: number; startedMs: number; belowSinceMs: number | null; lastMs: number }
  | { phase: "recovery"; holdIndex: number; recoveryUntilMs: number; unloaded: boolean; aboveSinceMs: number | null; lastMs: number; failed: boolean }
  | { phase: "complete"; lastMs: number; failed: boolean };

export type AdaptiveStaticAction =
  | { type: "start"; holdIndex: number; startedMs: number }
  | { type: "save"; holdIndex: number; outcome: "good" | "failed"; startedMs: number; endedMs: number; actualDurationMs: number }
  | { type: "finish" }
  | null;

export function adaptiveStaticHolds(timeline: readonly ProtocolSegment[]): AdaptiveStaticHold[] {
  const holds = timeline
    .map((segment, segmentIndex) => ({ segment, segmentIndex }))
    .filter((value) => value.segment.phase === "hold");
  return holds.map(({ segment, segmentIndex }, index) => {
    const next = holds[index + 1]?.segment;
    const endS = segment.startS + segment.durS;
    return {
      segmentIndex,
      set: segment.set,
      rep: segment.rep,
      side: segment.side ?? "",
      durationMs: Math.round(segment.durS * 1_000),
      recoveryMs: next ? Math.max(0, Math.round((next.startS - endS) * 1_000)) : 0,
    };
  });
}

export function armAdaptiveStatic(nowMs = 0): AdaptiveStaticState {
  return { phase: "armed", holdIndex: 0, aboveSinceMs: null, lastMs: nowMs };
}

/** Pure event-driven controller. Every returned action is claimed by the
 * returned state, so callers may persist it asynchronously without duplicates. */
export function stepAdaptiveStatic(
  state: AdaptiveStaticState,
  holds: readonly AdaptiveStaticHold[],
  sample: { atMs: number; kg: number },
  config: HandsFreeForceConfig = DEFAULT_HANDS_FREE_FORCE_CONFIG,
): { state: AdaptiveStaticState; action: AdaptiveStaticAction } {
  const atMs = Math.max(state.lastMs, sample.atMs);
  if (state.phase === "complete") return { state: { ...state, lastMs: atMs }, action: null };
  const hold = holds[state.holdIndex];
  if (!hold) {
    return {
      state: { phase: "complete", lastMs: atMs, failed: false },
      action: { type: "finish" },
    };
  }

  if (state.phase === "armed") {
    if (sample.kg < config.startKg) {
      return { state: { ...state, aboveSinceMs: null, lastMs: atMs }, action: null };
    }
    const aboveSinceMs = state.aboveSinceMs === null ? atMs : state.aboveSinceMs;
    if (atMs - aboveSinceMs < config.startStableMs) {
      return { state: { ...state, aboveSinceMs, lastMs: atMs }, action: null };
    }
    return {
      state: { phase: "hold", holdIndex: state.holdIndex, startedMs: atMs, belowSinceMs: null, lastMs: atMs },
      action: { type: "start", holdIndex: state.holdIndex, startedMs: atMs },
    };
  }

  if (state.phase === "hold") {
    const deadlineMs = state.startedMs + hold.durationMs;
    if (sample.kg <= config.stopKg) {
      const belowSinceMs = state.belowSinceMs === null ? atMs : state.belowSinceMs;
      // Only a release that BEGAN before the deadline can fail the rep. A
      // sample at/after the prescribed boundary means the hold was complete,
      // even though its release grace is confirmed later.
      if (belowSinceMs >= deadlineMs) {
        return finishAttempt(state, hold, holds.length, deadlineMs, "good", atMs);
      }
      if (atMs - belowSinceMs >= config.stopGraceMs) {
        return finishAttempt(state, hold, holds.length, belowSinceMs, "failed", atMs);
      }
      return { state: { ...state, belowSinceMs, lastMs: atMs }, action: null };
    }
    // A recovered brief dip cancels release. Success is intentionally checked
    // only while loaded, so a release whose grace crosses the deadline fails.
    if (atMs >= deadlineMs) return finishAttempt(state, hold, holds.length, deadlineMs, "good", atMs);
    return { state: { ...state, belowSinceMs: null, lastMs: atMs }, action: null };
  }

  const unloaded = state.unloaded || sample.kg <= config.stopKg;
  let aboveSinceMs = state.aboveSinceMs;
  if (!unloaded || sample.kg < config.startKg) aboveSinceMs = null;
  else if (aboveSinceMs === null) aboveSinceMs = atMs;
  if (unloaded && aboveSinceMs !== null && atMs - aboveSinceMs >= config.startStableMs) {
    return {
      state: { phase: "hold", holdIndex: state.holdIndex, startedMs: atMs, belowSinceMs: null, lastMs: atMs },
      action: { type: "start", holdIndex: state.holdIndex, startedMs: atMs },
    };
  }
  return { state: { ...state, unloaded, aboveSinceMs, lastMs: atMs }, action: null };
}

function finishAttempt(
  state: Extract<AdaptiveStaticState, { phase: "hold" }>,
  hold: AdaptiveStaticHold,
  holdCount: number,
  endedMs: number,
  outcome: "good" | "failed",
  observedMs: number,
): { state: AdaptiveStaticState; action: Exclude<AdaptiveStaticAction, null> } {
  const action = {
    type: "save" as const,
    holdIndex: state.holdIndex,
    outcome,
    startedMs: state.startedMs,
    endedMs,
    actualDurationMs: Math.max(1, endedMs - state.startedMs),
  };
  if (state.holdIndex + 1 >= holdCount) {
    return {
      state: { phase: "complete", lastMs: observedMs, failed: outcome === "failed" },
      action,
    };
  }
  return {
    state: {
      phase: "recovery",
      holdIndex: state.holdIndex + 1,
      recoveryUntilMs: endedMs + hold.recoveryMs,
      unloaded: outcome === "failed",
      aboveSinceMs: null,
      lastMs: observedMs,
      failed: outcome === "failed",
    },
    action,
  };
}
