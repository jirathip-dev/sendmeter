import { holdForSet, presetTargetKg } from "./protocol";
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
  side: "both" | null;
  targetKg: number | null;
  leftHoldS: number | null;
  rightHoldS: number | null;
  leftTargetKg: number | null;
  rightTargetKg: number | null;
}

export interface ResolvedAlternatingPlanSet {
  left: { holdS: number; targetKg: number | null };
  right: { holdS: number; targetKg: number | null };
}

/// One row per set `1..p.sets` — hold from `holdForSet`, target from
/// `presetTargetKg` (both already resolve per-set). An optional alternating
/// resolution carries each hand's own load and hold; otherwise alternating
/// presets apply the authored row to both hands.
export function buildPresetPlan(
  p: PlanPreset,
  refs: PresetRefs,
  resolvedAlternating?: readonly ResolvedAlternatingPlanSet[],
): PlanRow[] {
  return Array.from({ length: p.sets }, (_, i) => {
    const set = i + 1;
    const resolved = resolvedAlternating?.[i];
    const targetKg = presetTargetKg(p, refs, set);
    const holdS = holdForSet(p, set);
    return {
      set,
      holdS,
      side: p.alternateSides ? "both" : null,
      targetKg,
      leftHoldS: resolved?.left.holdS ?? (p.alternateSides ? holdS : null),
      rightHoldS: resolved?.right.holdS ?? (p.alternateSides ? holdS : null),
      leftTargetKg: resolved?.left.targetKg ?? (p.alternateSides ? targetKg : null),
      rightTargetKg: resolved?.right.targetKg ?? (p.alternateSides ? targetKg : null),
    };
  });
}

/// Whether the plan is worth charting — a single set, or a set list whose
/// holds, resolved (non-null) targets, and sides are all identical, looks no
/// different from the existing text summary.
export function planVaries(rows: PlanRow[], sets: number): boolean {
  if (sets <= 1) return false;
  const first = rows[0]!;
  const holdsVary = rows.some(
    (r) =>
      r.holdS !== first.holdS ||
      r.leftHoldS !== first.leftHoldS ||
      r.rightHoldS !== first.rightHoldS ||
      r.leftHoldS !== r.rightHoldS,
  );
  const targetsVary = rows.some(
    (r) =>
      r.targetKg !== first.targetKg ||
      r.leftTargetKg !== first.leftTargetKg ||
      r.rightTargetKg !== first.rightTargetKg ||
      r.leftTargetKg !== r.rightTargetKg,
  );
  const sidesVary = rows.some((r) => r.side !== rows[0]!.side);
  return holdsVary || targetsVary || sidesVary;
}

/// Whether the preset declares a target load at all (curve, %-of-PR/CF, or a
/// fixed kg) — distinct from "chosen but not yet resolvable" (curve mode
/// before a Hill capability fit exists, or %-of-PR before a PR exists), which is the only case
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
  const first = rows[0]!;
  const holdsVary = rows.some(
    (r) =>
      r.holdS !== first.holdS ||
      r.leftHoldS !== first.leftHoldS ||
      r.rightHoldS !== first.rightHoldS ||
      r.leftHoldS !== r.rightHoldS,
  );
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
