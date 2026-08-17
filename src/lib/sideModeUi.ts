import type { TindeqSide } from "../types";
import {
  normalizeSide,
  normalizeSideMode,
  type ExerciseSideMode,
} from "./sideMode";

/// Slice 2 of #543 (iPhone): how the shared slice-1 policy renders and
/// resolves a side SELECTION. `sideMode.ts` decides which sides are valid;
/// this module decides what a selector offers and what a save persists.
/// Components never hardcode a mode→options mapping — they read it here.

export interface SideOption {
  value: TindeqSide;
  label: string;
}

const SIDE_LABELS: Record<TindeqSide, string> = {
  "": "—",
  left: "Left",
  right: "Right",
  both: "Both",
};

/// The chips a side selector renders for a mode. `bilateral_only` and
/// `not_applicable` offer no choice — the mode fixes the side — so no chips
/// at all. `unilateral_only` offers Left/Right only ("" is "not chosen yet",
/// never a chip). The legacy default keeps the historical four chips, in the
/// same order, byte-for-byte.
export function sideOptionsFor(mode: ExerciseSideMode): SideOption[] {
  switch (mode) {
    case "bilateral_only":
    case "not_applicable":
      return [];
    case "unilateral_only":
      return [
        { value: "left", label: SIDE_LABELS.left },
        { value: "right", label: SIDE_LABELS.right },
      ];
    case "unilateral_or_bilateral":
      return [
        { value: "", label: SIDE_LABELS[""] },
        { value: "left", label: SIDE_LABELS.left },
        { value: "right", label: SIDE_LABELS.right },
        { value: "both", label: SIDE_LABELS.both },
      ];
  }
}

/// The side a selection RESOLVES to — what a save persists. Modes with no
/// choice fix the side outright: `bilateral_only` is always `both` (a fresh
/// selection must never record "" on a bilateral exercise — the mode defines
/// the side, and auto-setting it is not a reinterpretation of history) and
/// `not_applicable` is always the canonical "". Unilateral modes keep the
/// picked side, falling back via slice-1 `normalizeSide` when a mode change
/// left it invalid. This is deliberately distinct from `normalizeSide`,
/// which never maps "" → "both": that fallback governs historical/unspecified
/// values, this governs what the next recording gets.
export function selectionSide(
  mode: ExerciseSideMode,
  side: TindeqSide,
): TindeqSide {
  switch (mode) {
    case "bilateral_only":
      return "both";
    case "not_applicable":
      return "";
    default:
      return normalizeSide(mode, side);
  }
}

/// The label for a RESOLVED side in the "Side:" summary line. Separate from
/// `sideOptionsFor` because the summary shows the side even for modes with no
/// chips (e.g. "Side: Both" for a bilateral-only exercise).
export function sideLabel(side: TindeqSide): string {
  return SIDE_LABELS[side];
}

/// Whether a mode renders a "Side:" summary at all — `not_applicable` shows
/// no side text anywhere in setup/summary, so its exercises render neither
/// the label nor the chips.
export function sideSummaryVisible(mode: ExerciseSideMode): boolean {
  return mode !== "not_applicable";
}

/// The user-facing mode names for the Manage exercises selector.
export const SIDE_MODE_OPTIONS: { value: ExerciseSideMode; label: string }[] = [
  { value: "unilateral_or_bilateral", label: "Unilateral or bilateral" },
  { value: "unilateral_only", label: "Unilateral only" },
  { value: "bilateral_only", label: "Bilateral only" },
  { value: "not_applicable", label: "Not applicable" },
];

/// The mode for an exercise name from the fetched registry, falling back to
/// the legacy default for anything unconfigured (`normalizeSideMode`'s rule).
export function sideModeForTag(
  tag: string,
  registry: readonly { name: string; sideMode: ExerciseSideMode }[],
): ExerciseSideMode {
  return normalizeSideMode(
    registry.find((m) => m.name === tag)?.sideMode ?? null,
  );
}
