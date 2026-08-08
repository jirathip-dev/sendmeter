export const SHEET_CLOSE_DISTANCE_PX = 100;
export const SHEET_FLICK_MIN_DISTANCE_PX = 24;
export const SHEET_FLICK_VELOCITY_PX_PER_MS = 0.5;
export const SHEET_DRAG_SLOP_PX = 8;
export const SHEET_DRAG_AXIS_RATIO = 1.2;

export interface SheetDragIntent {
  dx: number;
  dy: number;
}

/**
 * The sheet owns only a downward, clearly vertical gesture that starts in its
 * top region. Horizontal intent is deliberately rejected here so a chart (or
 * any future horizontally interactive control) can never be claimed by the
 * sheet's dismiss handler.
 */
export function shouldStartSheetDrag({ dx, dy }: SheetDragIntent): boolean {
  const downwardDistance = Math.max(0, dy);
  return (
    downwardDistance >= SHEET_DRAG_SLOP_PX &&
    downwardDistance > Math.abs(dx) * SHEET_DRAG_AXIS_RATIO
  );
}

export interface SheetDragTargetInfo {
  tagName?: string;
  role?: string | null;
  classes?: readonly string[];
  contentEditable?: boolean;
}

/**
 * Interactive descendants of the top region are never drag handles. Keeping
 * this decision data-only makes the pointer contract easy to pin in Vitest
 * without a browser or testing-library dependency.
 */
export function isSheetDragExcludedTarget({
  tagName = "",
  role = null,
  classes = [],
  contentEditable = false,
}: SheetDragTargetInfo): boolean {
  const tag = tagName.toLowerCase();
  if (
    [
      "button",
      "a",
      "input",
      "textarea",
      "select",
      "option",
      "summary",
    ].includes(tag)
  ) {
    return true;
  }
  if (contentEditable) return true;
  if (role === "button" || role === "link" || role === "checkbox" || role === "switch") {
    return true;
  }
  return classes.includes("chart-scrub") || classes.includes("sheet-no-drag");
}

export interface SheetGestureDecision {
  dismissible: boolean;
  cancelled: boolean;
  distancePx: number;
  velocityPxPerMs: number;
}

/**
 * Decide whether releasing the bottom-sheet handle should dismiss the sheet.
 * A flick still needs meaningful downward travel so tiny, noisy movements do
 * not close the sheet solely because two pointer samples arrived close
 * together.
 */
export function shouldDismissSheetGesture({
  dismissible,
  cancelled,
  distancePx,
  velocityPxPerMs,
}: SheetGestureDecision): boolean {
  if (!dismissible || cancelled) return false;

  const downwardDistance = Math.max(0, distancePx);
  const downwardVelocity = Math.max(0, velocityPxPerMs);

  return (
    downwardDistance >= SHEET_CLOSE_DISTANCE_PX ||
    (downwardDistance >= SHEET_FLICK_MIN_DISTANCE_PX &&
      downwardVelocity >= SHEET_FLICK_VELOCITY_PX_PER_MS)
  );
}
