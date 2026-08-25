// KEEP-IN-SYNC: mirrored by
// ios/App/SendLogWatchCore/Sources/SendLogWatchCore/HandsFreeForce.swift.
// Keep phases, thresholds, timestamp recovery, and transition claims aligned;
// both runtimes intentionally make each action claim before async work.

export interface HandsFreeForceConfig {
  /// Load that must be held continuously before an armed pull begins.
  startKg: number;
  /// Lower release threshold. Keeping it below startKg provides hysteresis.
  stopKg: number;
  startStableMs: number;
  stopGraceMs: number;
  /// Guard 1 (#682): a rep peaking below this is a trivial non-rep and is
  /// discarded at persist time. Never raises the detection threshold: a
  /// recording that started is filtered only on full evidence at the save
  /// boundary.
  minPeakKg: number;
  /// Guard 1 (#682): a rep shorter than this is a trivial non-rep. Filtered
  /// at persist time, when the full duration is known.
  minDurationMs: number;
  /// Guard 2 (#682): a sustained load that stays inside a flatline band for
  /// this long is a non-human load and is terminated as `.staticLoad`.
  /// The guard keys on load SHAPE, not on "how long a human might hold":
  /// `ForceProtocol` holds can legitimately run up to 240 s (default 40 s),
  /// so this window is deliberately NOT "longer than any legitimate free
  /// hold". It is the COMBINATION of a tight 0.25 kg peak-to-peak band held
  /// continuously for 30 s that marks a dead/static load; a human hold's
  /// tremor/re-grip micro-adjustments normally break that band well before
  /// 30 s. Residual device-only risk: a genuinely motionless hand could in
  /// principle stay inside the band past the window, which the load-shape
  /// guard cannot distinguish from a dead load without an IMU signal.
  flatlineWindowMs: number;
  /// Guard 2 (#682): peak-to-peak band used to decide the load is flat.
  flatlineBandKg: number;
}

export const DEFAULT_HANDS_FREE_FORCE_CONFIG: HandsFreeForceConfig = {
  startKg: 2,
  stopKg: 1,
  startStableMs: 600,
  stopGraceMs: 1_500,
  minPeakKg: 3,
  minDurationMs: 1_500,
  flatlineWindowMs: 30_000,
  flatlineBandKg: 0.25,
};

export interface HandsFreeForceFlatWatch {
  /// Recording-clock time (ms) of the first sample of the current window.
  sinceMs: number;
  /// Rolling min kg since `sinceMs`.
  minKg: number;
  /// Rolling max kg since `sinceMs`.
  maxKg: number;
}

export type HandsFreeForceState =
  | { phase: "idle" }
  | { phase: "waitingForSlack" }
  | { phase: "armed"; aboveSinceMs: number | null }
  | { phase: "recording"; belowSinceMs: number | null; flatWatch: HandsFreeForceFlatWatch | null }
  | { phase: "stopping" };

export type HandsFreeForceAction = "start" | "stop" | null;

export interface HandsFreeForceStep {
  state: HandsFreeForceState;
  action: HandsFreeForceAction;
  /// Set (non-nil) only when `action === "stop"` because Guard 2 (#682)
  /// terminated the recording: the sustained flat load reached
  /// `flatlineWindowMs`. It is the START of the flat window on the recording
  /// clock — the trim the saved rep must end at. `null` for a release stop
  /// (the trim is derived from `belowSinceMs` at the call site) and every
  /// non-stop step.
  staticLoadEndMs: number | null;
}

export function armedHandsFreeForce(): HandsFreeForceState {
  return { phase: "armed", aboveSinceMs: null };
}

/// A post-save re-arm must observe an unloaded gauge before it can recognize
/// another pull. Otherwise a manual Stop & Save while still hanging turns the
/// same continuous load into a phantom second rep after `startStableMs`.
export function rearmedHandsFreeForce(): HandsFreeForceState {
  return { phase: "waitingForSlack" };
}

export function idleHandsFreeForce(): HandsFreeForceState {
  return { phase: "idle" };
}

/// Reconcile the control claim while the transport reports an inactive
/// status. `connected + armed/waitingForSlack` is the intentional overlap:
/// the state machine owns a live weight stream while the transport-facing
/// status remains connected.
export function handsFreeForceAtInactiveStatus(
  state: HandsFreeForceState,
  status: "connected" | "idle" | "unsupported",
): HandsFreeForceState {
  if (
    status === "connected" &&
    (state.phase === "armed" || state.phase === "waitingForSlack")
  ) {
    return state;
  }
  return state.phase === "idle" ? state : idleHandsFreeForce();
}

function advancingFlatWatch(
  current: HandsFreeForceFlatWatch | null,
  atMs: number,
  kg: number,
  config: HandsFreeForceConfig,
): HandsFreeForceFlatWatch {
  if (!current) return { sinceMs: atMs, minKg: kg, maxKg: kg };
  const minKg = Math.min(current.minKg, kg);
  const maxKg = Math.max(current.maxKg, kg);
  if (maxKg - minKg > config.flatlineBandKg) {
    return { sinceMs: atMs, minKg: kg, maxKg: kg };
  }
  return { sinceMs: current.sinceMs, minKg, maxKg };
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
    return { state, action: null, staticLoadEndMs: null };
  }

  if (state.phase === "waitingForSlack") {
    return sample.kg <= config.stopKg
      ? { state: armedHandsFreeForce(), action: null, staticLoadEndMs: null }
      : { state, action: null, staticLoadEndMs: null };
  }

  if (state.phase === "armed") {
    if (sample.kg < config.startKg) {
      return {
        state: state.aboveSinceMs === null ? state : { phase: "armed", aboveSinceMs: null },
        action: null,
        staticLoadEndMs: null,
      };
    }
    const aboveSinceMs =
      state.aboveSinceMs === null || sample.atMs < state.aboveSinceMs
        ? sample.atMs
        : state.aboveSinceMs;
    if (sample.atMs - aboveSinceMs >= config.startStableMs) {
      return {
        state: {
          phase: "recording",
          belowSinceMs: null,
          flatWatch: { sinceMs: sample.atMs, minKg: sample.kg, maxKg: sample.kg },
        },
        action: "start",
        staticLoadEndMs: null,
      };
    }
    return { state: { phase: "armed", aboveSinceMs }, action: null, staticLoadEndMs: null };
  }

  // state.phase === "recording"
  const flatWatch = advancingFlatWatch(state.flatWatch, sample.atMs, sample.kg, config);
  // Guard 2 (#682): a sustained flat load for flatlineWindowMs is a proven
  // non-human load — terminate before release detection. The trim is the
  // START of the flat window.
  if (flatWatch && sample.atMs - flatWatch.sinceMs >= config.flatlineWindowMs) {
    return { state: { phase: "stopping" }, action: "stop", staticLoadEndMs: flatWatch.sinceMs };
  }
  if (sample.kg > config.stopKg) {
    return {
      state: { phase: "recording", belowSinceMs: null, flatWatch },
      action: null,
      staticLoadEndMs: null,
    };
  }
  const belowSinceMs =
    state.belowSinceMs === null || sample.atMs < state.belowSinceMs
      ? sample.atMs
      : state.belowSinceMs;
  if (sample.atMs - belowSinceMs >= config.stopGraceMs) {
    return { state: { phase: "stopping" }, action: "stop", staticLoadEndMs: null };
  }
  return {
    state: { phase: "recording", belowSinceMs, flatWatch },
    action: null,
    staticLoadEndMs: null,
  };
}

/// Guard 1 (#682): the persist-boundary verdict for a hands-free rep. Runs
/// LAST, on the recording's final evidence, so a `.staticLoad`-terminated
/// rep is still evaluated here. A trivial non-rep is discarded silently and
/// must never enter the recording queue. KEEP-IN-SYNC with
/// `recordingVerdict` in `HandsFreeForce.swift`.
export type HandsFreeForceRecordingVerdict =
  | "persist"
  | { discard: "belowMinPeak" | "belowMinDuration" };

export function recordingVerdict(
  peakKg: number,
  durationMs: number,
  config: HandsFreeForceConfig = DEFAULT_HANDS_FREE_FORCE_CONFIG,
): HandsFreeForceRecordingVerdict {
  if (peakKg < config.minPeakKg) return { discard: "belowMinPeak" };
  if (durationMs < config.minDurationMs) return { discard: "belowMinDuration" };
  return "persist";
}
