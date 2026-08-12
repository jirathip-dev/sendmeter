import type { TindeqSide } from "../types";

/// Slice 1 of #543: per-exercise policy for which `TindeqSide` values are
/// valid, so a selector can adapt to the exercise instead of always offering
/// all four choices. Legacy/unconfigured exercises (including a missing
/// `tindeq_tags` registry row) default to `unilateral_or_bilateral` — the
/// pre-#543 behavior of allowing every side. `""` ("unspecified") and `both`
/// stay distinct everywhere: historical empty sides are never reinterpreted
/// as `both`.
export type ExerciseSideMode =
  | "unilateral_or_bilateral"
  | "unilateral_only"
  | "bilateral_only"
  | "not_applicable";

export const DEFAULT_SIDE_MODE: ExerciseSideMode = "unilateral_or_bilateral";

const SIDE_MODES = new Set<string>([
  "unilateral_or_bilateral",
  "unilateral_only",
  "bilateral_only",
  "not_applicable",
]);

/// Unknown/legacy mode strings (including a value that predates a later mode
/// being added) fall back to the default, never to an arbitrary guess.
export function normalizeSideMode(mode: string | null | undefined): ExerciseSideMode {
  return mode != null && SIDE_MODES.has(mode) ? (mode as ExerciseSideMode) : DEFAULT_SIDE_MODE;
}

const ALLOWED_SIDES: Record<ExerciseSideMode, readonly TindeqSide[]> = {
  unilateral_or_bilateral: ["", "left", "right", "both"],
  unilateral_only: ["", "left", "right"],
  bilateral_only: ["", "both"],
  not_applicable: [""],
};

/// The valid `TindeqSide` values for a mode. `""` ("unspecified") is always
/// included — it means "not chosen yet", not "not applicable".
export function allowedSides(mode: ExerciseSideMode): readonly TindeqSide[] {
  return ALLOWED_SIDES[mode];
}

export function isSideAllowed(mode: ExerciseSideMode, side: TindeqSide): boolean {
  return allowedSides(mode).includes(side);
}

/// Deterministic fallback for a remembered side that's no longer valid under
/// `mode` (e.g. the exercise's side_mode changed, or a preset carries a side
/// from before this exercise had a mode). `both` and `""` are never
/// substituted for each other.
export function normalizeSide(mode: ExerciseSideMode, side: TindeqSide): TindeqSide {
  if (isSideAllowed(mode, side)) return side;
  switch (mode) {
    case "bilateral_only":
      return "both";
    case "not_applicable":
      return "";
    case "unilateral_only":
      return "";
    case "unilateral_or_bilateral":
      return side;
  }
}
