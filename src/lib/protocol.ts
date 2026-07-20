import type { TindeqPreset } from "../types";

/// Guided-protocol timeline (pure — testable). A preset expands into a flat
/// list of timed segments; the UI and the per-rep recorder both walk it, so
/// countdowns and saved recordings can never disagree.
///
/// Alternating mode (SL-78): hands alternate per SET — set 1 runs every rep
/// LEFT, set 2 RIGHT, and so on. The set rest ends with a short SWITCH
/// countdown into the other hand (the rest is auto-extended to at least the
/// switch window). Within a set, rep rests are plain rests on the same hand.

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

/// Which hand a SET uses when the preset alternates: odd sets left, even
/// sets right.
export function setSide(set: number): "left" | "right" {
  return set % 2 === 1 ? "left" : "right";
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
/// The force references a preset resolves its target against, all from the
/// current exercise's force-duration model (null when not yet computed).
export interface PresetRefs {
  prKg: number | null; // best recorded peak
  cf: number | null; // critical force
  wPrime: number | null; // impulse above CF (kg·s)
  maxF: number | null; // best short-window force
}

/// Resolve a preset's target load (kg) for a given set, against the exercise's
/// force references. Priority: smart curve → % of PR/CF → fixed kg. Returns
/// null when the needed reference isn't available yet (band just doesn't show).
export function presetTargetKg(
  p: TindeqPreset,
  refs: PresetRefs,
  set: number,
): number | null {
  // Smart target (SL-62): force sustainable for exactly this hold — CF + W'/t,
  // capped at the best short-window force.
  if (p.targetCurve) {
    if (refs.cf == null || refs.wPrime == null || p.holdS <= 0) return null;
    const f = refs.cf + refs.wPrime / p.holdS;
    const capped = refs.maxF != null ? Math.min(refs.maxF, f) : f;
    return Math.round(capped * 10) / 10;
  }
  if (p.targetPct != null) {
    const base = p.pctBasis === "cf" ? refs.cf : refs.prKg;
    if (base == null || base <= 0) return null;
    const clampedSet = Math.max(1, Math.min(p.sets, set));
    const pct = Math.min(150, p.targetPct + (clampedSet - 1) * p.pctStep);
    return Math.round(((pct / 100) * base) * 10) / 10;
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
        // Per-SET alternation: every rep in this set is on one hand; the set
        // rest ends with a SWITCH countdown into the other hand.
        push("hold", setSide(set), rep, set, p.holdS);
        if (!lastRep) push("rest", null, rep, set, p.restRepsS);
        else if (!lastSet) {
          const eff = Math.max(p.restSetsS, switchS);
          push("setRest", null, rep, set, eff - switchS);
          push("switch", setSide(set + 1), rep, set, switchS);
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
