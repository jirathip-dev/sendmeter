import type { TindeqPreset } from "../types";

/// Guided-protocol timeline (pure — testable). A preset expands into a flat
/// list of timed segments; the UI and the per-rep recorder both walk it, so
/// countdowns and saved recordings can never disagree.
///
/// Alternating mode ("switch hands during the rest"): each preset rep is a
/// LEFT+RIGHT pair — hold L, a short SWITCH window, hold R (eating into the
/// rest), the remaining rest, then a SWITCH back to L before the next pair
/// (so BOTH hand changes get a countdown). If the rest is too short to fit
/// the switches + the other hand's hold, it's automatically extended:
/// effectiveRest = max(rest, switchS + holdS + switchS).

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

/// The target load for a given set: %-of-PR mode ramps per set
/// ((targetPct + (set-1)·pctStep)% of prKg, capped at 150%), otherwise the
/// absolute targetKg; null when the preset has no target (or %PR is set but
/// no PR exists yet for the exercise).
export function presetTargetKg(
  p: TindeqPreset,
  prKg: number | null,
  set: number,
): number | null {
  if (p.targetPct != null) {
    if (prKg == null || prKg <= 0) return null;
    const clampedSet = Math.max(1, Math.min(p.sets, set));
    const pct = Math.min(150, p.targetPct + (clampedSet - 1) * p.pctStep);
    return Math.round(((pct / 100) * prKg) * 10) / 10;
  }
  return p.targetKg;
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
        // The other hand's hold ate into the rest; what's left of the
        // (auto-extended) rest window plays out, ending with a switch back
        // to LEFT so the return change gets a countdown too.
        if (!(lastRep && lastSet)) {
          const nominal = lastRep ? p.restSetsS : p.restRepsS;
          const eff = Math.max(nominal, switchS + p.holdS + switchS);
          push(
            lastRep ? "setRest" : "rest",
            null,
            rep,
            set,
            eff - switchS - p.holdS - switchS,
          );
          push("switch", "left", rep, set, switchS);
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
