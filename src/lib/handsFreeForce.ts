export interface HandsFreeForceConfig {
  /// Load that must be held continuously before an armed pull begins.
  startKg: number;
  /// Lower release threshold. Keeping it below startKg provides hysteresis.
  stopKg: number;
  startStableMs: number;
  stopGraceMs: number;
}

export const DEFAULT_HANDS_FREE_FORCE_CONFIG: HandsFreeForceConfig = {
  startKg: 2,
  stopKg: 1,
  startStableMs: 600,
  stopGraceMs: 1_500,
};

export type HandsFreeForceState =
  | { phase: "idle" }
  | { phase: "armed"; aboveSinceMs: number | null }
  | { phase: "recording"; belowSinceMs: number | null }
  | { phase: "stopping" };

export type HandsFreeForceAction = "start" | "stop" | null;

export interface HandsFreeForceStep {
  state: HandsFreeForceState;
  action: HandsFreeForceAction;
}

export function armedHandsFreeForce(): HandsFreeForceState {
  return { phase: "armed", aboveSinceMs: null };
}

export function idleHandsFreeForce(): HandsFreeForceState {
  return { phase: "idle" };
}

/// Reconcile the control claim while the transport reports an inactive
/// status. `connected + armed` is the one intentional overlap: Arm claims the
/// machine synchronously, then the async transport may render once with its
/// old connected status before publishing armed.
export function handsFreeForceAtInactiveStatus(
  state: HandsFreeForceState,
  status: "connected" | "idle" | "unsupported",
): HandsFreeForceState {
  if (status === "connected" && state.phase === "armed") return state;
  return state.phase === "idle" ? state : idleHandsFreeForce();
}

/// Observe one live force sample. The returned state claims an emitted action
/// before the caller performs any async work: `recording` claims Start and
/// `stopping` claims Stop, so repeated samples cannot emit the same action.
export function stepHandsFreeForce(
  state: HandsFreeForceState,
  sample: { atMs: number; kg: number },
  config: HandsFreeForceConfig = DEFAULT_HANDS_FREE_FORCE_CONFIG,
): HandsFreeForceStep {
  if (state.phase === "idle" || state.phase === "stopping") {
    return { state, action: null };
  }

  if (state.phase === "armed") {
    if (sample.kg < config.startKg) {
      return {
        state: state.aboveSinceMs === null ? state : { phase: "armed", aboveSinceMs: null },
        action: null,
      };
    }
    const aboveSinceMs =
      state.aboveSinceMs === null || sample.atMs < state.aboveSinceMs
        ? sample.atMs
        : state.aboveSinceMs;
    if (sample.atMs - aboveSinceMs >= config.startStableMs) {
      return { state: { phase: "recording", belowSinceMs: null }, action: "start" };
    }
    return { state: { phase: "armed", aboveSinceMs }, action: null };
  }

  if (sample.kg > config.stopKg) {
    return {
      state: state.belowSinceMs === null ? state : { phase: "recording", belowSinceMs: null },
      action: null,
    };
  }
  const belowSinceMs =
    state.belowSinceMs === null || sample.atMs < state.belowSinceMs
      ? sample.atMs
      : state.belowSinceMs;
  if (sample.atMs - belowSinceMs >= config.stopGraceMs) {
    return { state: { phase: "stopping" }, action: "stop" };
  }
  return { state: { phase: "recording", belowSinceMs }, action: null };
}
