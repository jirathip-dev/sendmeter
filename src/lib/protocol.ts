import type { TindeqPreset } from "../types";

/// Guided-protocol timeline (pure — testable). A preset expands into a flat
/// list of timed segments; the UI and the per-rep recorder both walk it, so
/// countdowns and saved recordings can never disagree.
///
/// Alternating mode ("switch hands during the rest"): each preset rep is a
/// LEFT+RIGHT pair — hold L, a short SWITCH window, hold R (eating into the
/// rest), then whatever rest remains. If the rest is too short to fit the
/// switch + the other hand's hold, it's automatically extended so the pair
/// always fits: effectiveRest = max(rest, switchS + holdS).

export interface ProtocolSegment {
  phase: "prepare" | "hold" | "switch" | "rest" | "setRest";
  /// Hand for a hold ("left"/"right" when alternating; null = the user's
  /// selected side applies).
  side: "left" | "right" | null;
  rep: number;
  set: number;
  startS: number;
  durS: number;
}

export interface TimelinePosition {
  seg: ProtocolSegment;
  remaining: number;
}

/// Which hand a rep uses when the preset alternates: pairs always run
/// left-then-right.
export function repSide(rep: number): "left" | "right" {
  return rep % 2 === 1 ? "left" : "right";
}

/// Nominal (non-alternating) duration — the quick summary shown on preset
/// rows. Alternating timelines can run longer; use timelineDurationS for
/// the exact figure.
export function protocolDurationS(p: TindeqPreset): number {
  const setWork = p.reps * p.holdS + (p.reps - 1) * p.restRepsS;
  return p.sets * setWork + (p.sets - 1) * p.restSetsS;
}

export function buildTimeline(
  p: TindeqPreset,
  opts: { switchS?: number; prepareS?: number } = {},
): ProtocolSegment[] {
  const switchS = opts.switchS ?? 3;
  const prepareS = opts.prepareS ?? 0;
  const segs: ProtocolSegment[] = [];
  let t = 0;
  const push = (
    phase: ProtocolSegment["phase"],
    side: ProtocolSegment["side"],
    rep: number,
    set: number,
    durS: number,
  ) => {
    if (durS <= 0) return;
    segs.push({ phase, side, rep, set, startS: t, durS });
    t += durS;
  };

  if (prepareS > 0) push("prepare", null, 1, 1, prepareS);

  for (let set = 1; set <= p.sets; set++) {
    for (let rep = 1; rep <= p.reps; rep++) {
      const lastRep = rep === p.reps;
      const lastSet = set === p.sets;
      if (p.alternateSides) {
        push("hold", "left", rep, set, p.holdS);
        push("switch", "right", rep, set, switchS);
        push("hold", "right", rep, set, p.holdS);
        // The other hand's hold ate into the rest; the remainder is what's
        // left of an auto-extended rest window.
        if (!lastRep) {
          const eff = Math.max(p.restRepsS, switchS + p.holdS);
          push("rest", null, rep, set, eff - switchS - p.holdS);
        } else if (!lastSet) {
          const eff = Math.max(p.restSetsS, switchS + p.holdS);
          push("setRest", null, rep, set, eff - switchS - p.holdS);
        }
      } else {
        push("hold", null, rep, set, p.holdS);
        if (!lastRep) push("rest", null, rep, set, p.restRepsS);
        else if (!lastSet) push("setRest", null, rep, set, p.restSetsS);
      }
    }
  }
  return segs;
}

export function timelineDurationS(segs: ProtocolSegment[]): number {
  const last = segs[segs.length - 1];
  return last ? last.startS + last.durS : 0;
}

/// Where the protocol is at `t` seconds after Start. Null = done.
export function timelineAt(
  segs: ProtocolSegment[],
  t: number,
): TimelinePosition | null {
  for (const seg of segs) {
    if (t < seg.startS + seg.durS) {
      return { seg, remaining: seg.startS + seg.durS - Math.max(t, seg.startS) };
    }
  }
  return null;
}
