import type { ProtocolSegment } from "./protocol";

export type TargetZone = "unknown" | "below" | "in-zone" | "above";
export type TargetZoneCue = Exclude<TargetZone, "unknown">;

export interface TargetZoneCoachConfig {
  /// Force must clear an edge by this much before leaving the committed zone.
  hysteresisKg: number;
  /// A candidate zone must remain unchanged for this long before it commits.
  dwellMs: number;
}

export const DEFAULT_TARGET_ZONE_COACH_CONFIG: TargetZoneCoachConfig = {
  hysteresisKg: 0.3,
  dwellMs: 350,
};

export interface TargetZoneCoachInput {
  currentKg: number;
  targetLowKg: number | null;
  targetHighKg: number | null;
  timestampMs: number;
  active: boolean;
}

export interface TargetZoneCoachState {
  zone: TargetZone;
  candidateZone: TargetZoneCue | null;
  candidateSinceMs: number | null;
  lastTimestampMs: number | null;
  targetLowKg: number | null;
  targetHighKg: number | null;
}

export interface TargetZoneCoachStep {
  state: TargetZoneCoachState;
  cue: TargetZoneCue | null;
}

export function idleTargetZoneCoach(): TargetZoneCoachState {
  return {
    zone: "unknown",
    candidateZone: null,
    candidateSinceMs: null,
    lastTimestampMs: null,
    targetLowKg: null,
    targetHighKg: null,
  };
}

function validInput(
  input: TargetZoneCoachInput,
  config: TargetZoneCoachConfig,
): input is TargetZoneCoachInput & { targetLowKg: number; targetHighKg: number } {
  return (
    input.active &&
    Number.isFinite(input.currentKg) &&
    Number.isFinite(input.timestampMs) &&
    input.targetLowKg !== null &&
    input.targetHighKg !== null &&
    Number.isFinite(input.targetLowKg) &&
    Number.isFinite(input.targetHighKg) &&
    input.targetLowKg < input.targetHighKg &&
    Number.isFinite(config.hysteresisKg) &&
    config.hysteresisKg >= 0 &&
    Number.isFinite(config.dwellMs) &&
    config.dwellMs >= 300
  );
}

function rawZone(kg: number, lowKg: number, highKg: number): TargetZoneCue {
  if (kg < lowKg) return "below";
  if (kg > highKg) return "above";
  return "in-zone";
}

/// Apply hysteresis relative to the currently committed zone. Exact target
/// edges belong to the band; after leaving it, re-entry must clear the edge by
/// `hysteresisKg` so boundary noise cannot flip the candidate back and forth.
function observedZone(
  committed: TargetZone,
  kg: number,
  lowKg: number,
  highKg: number,
  hysteresisKg: number,
): TargetZoneCue {
  if (committed === "below") {
    if (kg < lowKg + hysteresisKg) return "below";
    return kg > highKg ? "above" : "in-zone";
  }
  if (committed === "above") {
    if (kg > highKg - hysteresisKg) return "above";
    return kg < lowKg ? "below" : "in-zone";
  }
  if (committed === "in-zone") {
    if (kg < lowKg - hysteresisKg) return "below";
    if (kg > highKg + hysteresisKg) return "above";
    return "in-zone";
  }
  return rawZone(kg, lowKg, highKg);
}

function beginObservation(
  input: TargetZoneCoachInput & { targetLowKg: number; targetHighKg: number },
): TargetZoneCoachState {
  return {
    zone: "unknown",
    candidateZone: rawZone(input.currentKg, input.targetLowKg, input.targetHighKg),
    candidateSinceMs: input.timestampMs,
    lastTimestampMs: input.timestampMs,
    targetLowKg: input.targetLowKg,
    targetHighKg: input.targetHighKg,
  };
}

/// Observe one force sample. A returned cue is already claimed in `state.zone`
/// before the caller performs audio work, so feeding the returned state into
/// repeated or concurrent callbacks cannot emit the same transition twice.
export function stepTargetZoneCoach(
  state: TargetZoneCoachState,
  input: TargetZoneCoachInput,
  config: TargetZoneCoachConfig = DEFAULT_TARGET_ZONE_COACH_CONFIG,
): TargetZoneCoachStep {
  if (!validInput(input, config)) {
    return { state: idleTargetZoneCoach(), cue: null };
  }

  const bandChanged =
    state.targetLowKg !== input.targetLowKg || state.targetHighKg !== input.targetHighKg;
  const timestampRolledBack =
    state.lastTimestampMs !== null && input.timestampMs < state.lastTimestampMs;
  if (bandChanged || timestampRolledBack) {
    return { state: beginObservation(input), cue: null };
  }

  const observed = observedZone(
    state.zone,
    input.currentKg,
    input.targetLowKg,
    input.targetHighKg,
    config.hysteresisKg,
  );

  if (observed === state.zone) {
    return {
      state: {
        ...state,
        candidateZone: null,
        candidateSinceMs: null,
        lastTimestampMs: input.timestampMs,
      },
      cue: null,
    };
  }

  const candidateSinceMs =
    observed === state.candidateZone && state.candidateSinceMs !== null
      ? state.candidateSinceMs
      : input.timestampMs;
  if (input.timestampMs - candidateSinceMs < config.dwellMs) {
    return {
      state: {
        ...state,
        candidateZone: observed,
        candidateSinceMs,
        lastTimestampMs: input.timestampMs,
      },
      cue: null,
    };
  }

  return {
    state: {
      zone: observed,
      candidateZone: null,
      candidateSinceMs: null,
      lastTimestampMs: input.timestampMs,
      targetLowKg: input.targetLowKg,
      targetHighKg: input.targetHighKg,
    },
    cue: observed,
  };
}

export interface TargetZoneCoachActivity {
  enabled: boolean;
  measuring: boolean;
  hasTarget: boolean;
  guided: boolean;
  guidedPhase: ProtocolSegment["phase"] | "move" | null;
  paused: boolean;
}

/// The component gate kept pure for coverage: free holds coach throughout the
/// measurement, while guided runs coach only their actual hold segments.
export function targetZoneCoachActive(activity: TargetZoneCoachActivity): boolean {
  if (!activity.enabled || !activity.measuring || !activity.hasTarget || activity.paused) {
    return false;
  }
  return (
    !activity.guided ||
    activity.guidedPhase === "hold" ||
    activity.guidedPhase === "move"
  );
}
