import type { TindeqPreset } from "../types";

/// Where a preset protocol is at `t` seconds after Start (pure — testable).
/// Timeline per set: reps × (HOLD hold_s → REST rest_reps_s), with the last
/// rep's rep-rest replaced by the set-rest (or nothing after the final set).
export interface ProtocolPhase {
  phase: "hold" | "rest" | "setRest" | "done";
  /// Seconds left in the current phase (0 for done).
  remaining: number;
  /// 1-based rep/set currently in progress (clamped to the last on done).
  rep: number;
  set: number;
}

export function protocolDurationS(p: TindeqPreset): number {
  const setWork = p.reps * p.holdS + (p.reps - 1) * p.restRepsS;
  return p.sets * setWork + (p.sets - 1) * p.restSetsS;
}

/// Which hand a rep uses when the preset alternates sides: odd reps left,
/// even reps right (restarting every set), switching during each rep rest.
export function repSide(rep: number): "left" | "right" {
  return rep % 2 === 1 ? "left" : "right";
}

export function protocolPhaseAt(p: TindeqPreset, t: number): ProtocolPhase {
  const setWork = p.reps * p.holdS + (p.reps - 1) * p.restRepsS;
  const setBlock = setWork + p.restSetsS;

  if (t >= protocolDurationS(p)) {
    return { phase: "done", remaining: 0, rep: p.reps, set: p.sets };
  }

  const set = Math.min(p.sets, Math.floor(t / setBlock) + 1);
  let tInSet = t - (set - 1) * setBlock;

  if (tInSet >= setWork) {
    // Between sets
    return {
      phase: "setRest",
      remaining: setBlock - tInSet,
      rep: p.reps,
      set,
    };
  }

  const repBlock = p.holdS + p.restRepsS;
  const rep = Math.min(p.reps, Math.floor(tInSet / repBlock) + 1);
  tInSet -= (rep - 1) * repBlock;

  if (tInSet < p.holdS) {
    return { phase: "hold", remaining: p.holdS - tInSet, rep, set };
  }
  return { phase: "rest", remaining: repBlock - tInSet, rep, set };
}
