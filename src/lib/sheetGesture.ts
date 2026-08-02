export const SHEET_CLOSE_DISTANCE_PX = 100;
export const SHEET_FLICK_MIN_DISTANCE_PX = 24;
export const SHEET_FLICK_VELOCITY_PX_PER_MS = 0.5;

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
