import type { TindeqPreset } from "../types";
import { predictCapability } from "./force-curve";
import type { CapabilityFit } from "./capabilityModel";
import type { PlanPreset } from "./presetPlan";

/// Guided-protocol timeline (pure — testable). A preset expands into a flat
/// list of timed segments; the UI and the per-rep recorder both walk it, so
/// countdowns and saved recordings can never disagree.
///
/// Alternating mode: every logical rep runs LEFT then RIGHT with the same rep
/// and set numbers. The opposite hand's hold consumes part of the configured
/// same-hand recovery; every hand change still gets at least `switchS`.

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

/** Per-hand hold durations for an alternating protocol, indexed by set. */
export interface AlternatingHoldDurations {
  left: readonly number[];
  right: readonly number[];
}

/// The hold duration for a given SET (#332) — `set` clamps to `1..p.sets`.
/// Falls back to the base `holdS` when `holdsS` is null OR shorter than
/// `sets` (a preset saved before this field, or whose `sets` was since
/// raised past the list's length, must keep behaving exactly as before).
export function holdForSet(p: PlanPreset, set: number): number {
  const clamped = Math.max(1, Math.min(p.sets, set));
  if (!p.holdsS || p.holdsS.length < p.sets) return p.holdS;
  return p.holdsS[clamped - 1] ?? p.holdS;
}

/// Every set's resolved hold, in order — drives UI summaries (preset row,
/// READY line) that want the whole per-set shape rather than one set's value.
export function holdsForSets(p: PlanPreset): number[] {
  return Array.from({ length: p.sets }, (_, i) => holdForSet(p, i + 1));
}

/// Same `<60s ? "Ns" : "Mm[Ss]"` rule PresetManager's row uses for rest
/// times — exported so `PresetPlanChart` formats a per-set hold label
/// exactly like `holdsSummary` does (e.g. `4m` for 240s, not a raw count).
export function fmtHoldS(s: number): string {
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  const rem = s % 60;
  return rem === 0 ? `${m}m` : `${m}m${rem}s`;
}

/// Human-readable hold summary for a preset row / READY line: `"7s"` (or
/// `"4m"` for ≥60s) when every set holds the same duration (today's shape,
/// unchanged), or `"5s→1m10s"` when it varies — capped at the first 4 sets
/// (mirrors the %-of-PR ramp summary in PresetManager) so a long protocol's
/// line doesn't run away.
export function holdsSummary(p: TindeqPreset): string {
  const holds = holdsForSets(p);
  if (holds.every((h) => h === holds[0])) return fmtHoldS(holds[0]!);
  const shown = holds.slice(0, 4);
  const suffix = holds.length > 4 ? "→…" : "";
  return `${shown.map(fmtHoldS).join("→")}${suffix}`;
}

/// Preset-editor derivation (#332) — given the raw form fields (base hold,
/// per-set overrides typed so far, `sets`, and whether "vary hold per set" is
/// checked), resolve what gets saved. `holds` slots are `null` for any set the
/// user hasn't typed into — those keep following the live `holdS` (round 3
/// finding 1: a slot must never be frozen at whatever `holdS` happened to be
/// when a DIFFERENT slot was edited), and the array may be shorter (unedited
/// tail) or longer (after lowering `sets`) than `sets`, both of which also
/// fall back to `holdS`. `holdsS` is null whenever the checkbox is off OR
/// every resolved slot is equal, so an unvaried preset keeps today's shape.
/// `holdBase` is what a pre-#332 reader — and the auto-name fallback — should
/// use: set 1's resolved value when varying, else the raw `holdS` field.
export function deriveHoldsField(
  varyHolds: boolean,
  holdS: number,
  holds: (number | null)[],
  sets: number,
): { holdBase: number; holdsS: number[] | null; resolved: number[] } {
  const resolved = Array.from({ length: sets }, (_, i) => holds[i] ?? holdS);
  const varying = varyHolds && resolved.some((h) => h !== resolved[0]);
  return {
    holdBase: varying ? resolved[0]! : holdS,
    holdsS: varying ? resolved : null,
    resolved,
  };
}

/// Applies one per-set hold-field edit. Writes `value` at `index` and leaves
/// every other slot exactly as it was — in particular, a slot the user has
/// never typed into stays `null` rather than getting materialized to its
/// currently-resolved value, so `deriveHoldsField`'s `holds[i] ?? holdS`
/// keeps tracking a later change to the base `holdS` instead of freezing at
/// whatever it was when a sibling slot got edited (#332 round 3 finding 1).
/// This also preserves any slot typed while `sets` was higher (round 2
/// finding 1) for free — untouched slots past the current `sets` are simply
/// left alone, not truncated.
export function applyHoldEdit(
  prev: (number | null)[],
  index: number,
  value: number,
): (number | null)[] {
  const next = prev.slice();
  while (next.length <= index) next.push(null);
  next[index] = value;
  return next;
}

/// Guards a per-set hold-field commit against `NumInput`'s fire-every-blur
/// behavior (#332 round 6 finding b): `NumInput.commit` calls `onCommit`
/// unconditionally on blur, even when the field was only focused and blurred
/// without being typed into — tabbing/tapping through the row alone would
/// otherwise run every slot through `applyHoldEdit` and materialize it,
/// exactly the freeze `applyHoldEdit`'s "null until typed" invariant exists
/// to prevent. Skip the write when the slot is still unset AND the committed
/// value equals what was already displayed (`deriveHoldsField`'s resolved
/// value for that slot) — nothing actually changed, so the slot stays null
/// and keeps following the base `holdS`.
export function commitHoldEdit(
  prev: (number | null)[],
  index: number,
  value: number,
  displayedValue: number,
): (number | null)[] {
  if (prev[index] == null && value === displayedValue) return prev;
  return applyHoldEdit(prev, index, value);
}

/// Nominal (non-alternating) duration — the quick summary shown on preset
/// rows. Alternating timelines can run longer; use timelineDurationS for
/// the exact figure.
export function protocolDurationS(p: TindeqPreset): number {
  const holdWork = holdsForSets(p).reduce((sum, h) => sum + p.reps * h, 0);
  const setWork = holdWork + p.sets * (p.reps - 1) * p.restRepsS;
  return setWork + (p.sets - 1) * p.restSetsS;
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
  capabilityFit?: CapabilityFit | null; // frozen Hill capability curve
}

/// Resolve a preset's target load (kg) for a given set, against the exercise's
/// force references. Priority: smart curve → % of PR/CF → fixed kg. Returns
/// null when the needed reference isn't available yet (band just doesn't show).
export function presetTargetKg(
  p: PlanPreset,
  refs: PresetRefs,
  set: number,
): number | null {
  // Auto curve: force sustainable for exactly this hold from the visible Hill
  // capability curve. #332: resolved at THIS set's hold
  // (a per-set hold list moves the curve reference set-by-set, same as the
  // %-of-PR ramp below moves the load).
  if (p.targetCurve) {
    const h = holdForSet(p, set);
    const f = predictCapability({ capabilityFit: refs.capabilityFit ?? undefined }, h);
    return f == null ? null : Math.round(f * 10) / 10;
  }
  if (p.targetPct != null) {
    const base = p.pctBasis === "cf" ? refs.cf : refs.prKg;
    if (base == null || base <= 0) return null;
    const clampedSet = Math.max(1, Math.min(p.sets, set));
    const pct = Math.min(150, p.targetPct + (clampedSet - 1) * p.pctStep);
    return Math.round(((pct / 100) * base) * 10) / 10;
  }
  // Fixed-kg mode: pass the stored value through as-is. Rounding here was
  // scope creep from the badge work (SL-103/#105) — this branch feeds the
  // live gauge band and presetKgSet1 too, not just the badge. Consumers that
  // want a rounded display already `.toFixed(1)` it (PresetManager); the
  // badge classifier only compares it against maxF/CF thresholds, where sub-
  // 0.1kg precision is immaterial.
  return p.targetKg == null ? null : p.targetKg;
}

/// Full min/max range of a preset's resolved target across ALL its sets
/// (#332) — a per-set hold list moves a `targetCurve` (or %-ramp) target
/// non-monotonically in general, so picking just set 1 and the last set (as
/// the badge/row work did before this) can miss a middle set that's actually
/// the extreme. Null wherever `presetTargetKg` is (no target, or a needed
/// reference isn't resolved yet) — that's uniform across sets since only the
/// per-set hold/pct varies, not the refs the target resolves against.
export function presetTargetKgRange(
  p: PlanPreset,
  refs: PresetRefs,
): { min: number; max: number } | null {
  const kgs: number[] = [];
  for (let set = 1; set <= p.sets; set++) {
    const kg = presetTargetKg(p, refs, set);
    if (kg == null) return null;
    kgs.push(kg);
  }
  return { min: Math.min(...kgs), max: Math.max(...kgs) };
}

/// `"X.X kg"` when a range's ends coincide, else `"X.X–Y.Y kg"` — the
/// shared format for `presetTargetKgRange` wherever it's shown (preset row,
/// fullscreen band label).
export function formatKgRange(range: { min: number; max: number }): string {
  return range.min === range.max
    ? `${range.min.toFixed(1)} kg`
    : `${range.min.toFixed(1)}–${range.max.toFixed(1)} kg`;
}

/// Preset-editor "Auto (curve)" slider label + explanation (#332 round 6
/// finding c). With `varyHolds` off, the slider sets the ONE hold every set's
/// smart target resolves against, and the old sentence ("read off this
/// exercise's Hill capability curve") is exactly true. With
/// `varyHolds` on, `presetTargetKg` resolves each set's target at THAT set's
/// `holdForSet` — a set with its own "Set N" override reads its target off
/// that hold, not this slider's — so the old sentence's stated formula is
/// false for any overridden set. Relabel the slider "base hold time (sets
/// without an override)" and say so, rather than hiding it: sets left at
/// their default still resolve off this value.
export function curveHoldCopy(
  varyHolds: boolean,
  holdS: number,
): { label: string; description: string } {
  if (varyHolds) {
    return {
      label: `Base hold time (sets without an override) — ${holdS}s`,
      description:
        `Auto curve: each set's load adjusts to the force sustainable ` +
        `for THAT set's hold, read off this exercise's purple Hill capability ` +
        `curve. A set left without its own "Set N" override above uses ` +
        `this ${holdS}s base. Longer holds → lighter, more endurance-y load.`,
    };
  }
  return {
    label: `Hold time — ${holdS}s`,
    description:
      `Auto curve: the load adjusts to the force you can sustain ` +
      `for a ${holdS}s hold, read off this exercise's purple Hill capability ` +
      `curve. Longer holds → lighter, more endurance-y load.`,
  };
}

/// Fullscreen live-gauge band label (#332 round 6 finding a). A `targetCurve`
/// preset only earns the "· set N: X kg (range)" parenthetical when the
/// per-set holds actually make the target vary across sets — a uniform
/// preset (today's default: `holdsS` null) renders the bare protocol name,
/// exactly as it did before this feature (curve presets have `targetPct ===
/// null`, so they always fell through to the bare name pre-#332). Mirrors the
/// %-of-PR branch's existing "no variation → bare name" shape instead of
/// introducing a new always-on annotation.
export function protocolBandLabel(
  p: TindeqPreset,
  protocolKg: number,
  currentSet: number,
  kgRange: { min: number; max: number } | null,
): string {
  if (p.targetCurve) {
    return kgRange && kgRange.min !== kgRange.max
      ? `${p.name} · set ${currentSet}: ${protocolKg.toFixed(1)} kg (${formatKgRange(kgRange)})`
      : p.name;
  }
  return p.targetPct != null && p.sets > 1
    ? `${p.name} · set ${currentSet}: ${protocolKg.toFixed(1)} kg`
    : p.name;
}

export function buildTimeline(
  p: TindeqPreset,
  opts: {
    switchS?: number;
    prepareS?: number;
    alternatingHolds?: AlternatingHoldDurations;
  } = {},
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

  const alternatingHold = (side: "left" | "right", set: number): number => {
    const resolved = opts.alternatingHolds?.[side][set - 1];
    return resolved != null && resolved > 0 ? resolved : holdForSet(p, set);
  };

  for (let set = 1; set <= p.sets; set++) {
    const hold = holdForSet(p, set);
    for (let rep = 1; rep <= p.reps; rep++) {
      const lastRep = rep === p.reps;
      const lastSet = set === p.sets;
      if (p.alternateSides) {
        const leftHold = alternatingHold("left", set);
        const rightHold = alternatingHold("right", set);
        push("hold", "left", rep, set, leftHold);
        push("switch", "right", rep, set, switchS);
        push("hold", "right", rep, set, rightHold);

        if (!lastRep || !lastSet) {
          const configuredRest = lastRep ? p.restSetsS : p.restRepsS;
          const nextSet = lastRep ? set + 1 : set;
          const nextLeftHold = alternatingHold("left", nextSet);
          // The opposite-hand hold consumes same-hand recovery. When the two
          // holds differ, subtract the shorter adjacent hold so neither hand
          // receives less than the configured recovery interval.
          const recoveryCredit = Math.min(rightHold, nextLeftHold);
          const remainingGap = Math.max(configuredRest - recoveryCredit, switchS);
          push(lastRep ? "setRest" : "rest", null, rep, set, remainingGap - switchS);
          push("switch", "left", rep, set, switchS);
        }
      } else {
        push("hold", null, rep, set, hold);
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

/// The hand the FIRST hold segment uses (#298) — for a UI that wants to show
/// which side an alternating protocol starts on before any segment is
/// "current" (idle, or after Stop). `segs[0]` is NOT this: with the get-ready
/// countdown on by default, segment 0 is `prepare`, whose `side` is always
/// null.
export function firstHoldSide(
  segs: ProtocolSegment[],
): ProtocolSegment["side"] {
  return segs.find((s) => s.phase === "hold")?.side ?? null;
}
