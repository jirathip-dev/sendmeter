import { holdForSet, presetTargetKg, setSide } from "./protocol";
import type { PresetRefs } from "./protocol";
import type { TindeqPreset } from "../types";

/// Part 2 of #332/#331: the per-set *plan* a preset resolves to, legible
/// before a run starts (`PresetPlanChart`). `id`/`name` are omitted so the
/// editor's live form state satisfies this without fabricating a fake id —
/// both a saved preset and the editor's draft build the same plan.
export type PlanPreset = Omit<TindeqPreset, "id" | "name">;

export interface PlanRow {
  set: number;
  holdS: number;
  side: "left" | "right" | null;
  targetKg: number | null;
}

/// One row per set `1..p.sets` — hold from `holdForSet`, target from
/// `presetTargetKg` (both already resolve per-set), or from the optional
/// already-resolved per-hand/set targets (#331); side from `setSide` only
/// when the preset alternates (otherwise the user's selected side applies,
/// which this plan doesn't know).
export function buildPresetPlan(
  p: PlanPreset,
  refs: PresetRefs,
  resolvedTargets?: readonly (number | null)[],
): PlanRow[] {
  return Array.from({ length: p.sets }, (_, i) => {
    const set = i + 1;
    return {
      set,
      holdS: holdForSet(p, set),
      side: p.alternateSides ? setSide(set) : null,
      targetKg: resolvedTargets ? (resolvedTargets[i] ?? null) : presetTargetKg(p, refs, set),
    };
  });
}

/// Whether the plan is worth charting — a single set, or a set list whose
/// holds, resolved (non-null) targets, and sides are all identical, looks no
/// different from the existing text summary.
export function planVaries(rows: PlanRow[], sets: number): boolean {
  if (sets <= 1) return false;
  const holdsVary = rows.some((r) => r.holdS !== rows[0]!.holdS);
  const targets = rows.map((r) => r.targetKg).filter((t): t is number => t != null);
  const targetsVary = targets.some((t) => t !== targets[0]);
  const sidesVary = rows.some((r) => r.side !== rows[0]!.side);
  return holdsVary || targetsVary || sidesVary;
}

/// Whether the preset declares a target load at all (curve, %-of-PR/CF, or a
/// fixed kg) — distinct from "chosen but not yet resolvable" (curve mode
/// before CF/W′ exist, or %-of-PR before a PR exists), which is the only case
/// that deserves a "not resolvable yet" caption. A preset left on Target
/// load: None resolves every `targetKg` to null too, but has nothing pending.
export function presetHasTarget(p: PlanPreset): boolean {
  return p.targetCurve || p.targetPct != null || p.targetKg != null;
}

export type PlanMetric = "hold" | "target";

/// Which quantity the chart's bar height should represent. Hold time by
/// default — the common case, and the only one when holds vary. When holds
/// are flat and only the target ramps (e.g. a %-of-PR ramp with uniform
/// holds — presetPlan.test.ts's `pctStep` case), every bar would otherwise
/// render at identical height while the only sign of variation is the 7.5px
/// caption underneath; switch the bars to plot `targetKg` instead so the
/// primary visual channel matches whatever `planVaries` actually found.
export function planMetric(rows: PlanRow[]): PlanMetric {
  const holdsVary = rows.some((r) => r.holdS !== rows[0]!.holdS);
  return holdsVary ? "hold" : "target";
}

/// Below-bar labels ("targetKg · side") and per-bar top labels can overprint
/// once sets get numerous — SVG doesn't wrap or truncate text. Thresholds
/// are the labels' actual rendered widths at their fixed font sizes (top
/// label ~22 user units at fontSize 8, below label ~40 at fontSize 7.5),
/// each with a small margin, so a bar+gap pitch narrower than that would
/// touch or overlap its neighbor.
export function planLabelVisibility(cellW: number): { showHold: boolean; showBelow: boolean } {
  return { showHold: cellW >= 24, showBelow: cellW >= 42 };
}
