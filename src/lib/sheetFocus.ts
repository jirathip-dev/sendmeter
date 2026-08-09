/**
 * Return the next focusable index when focus containment wraps at either end
 * of a dialog. This deliberately has no DOM dependency; Sheet supplies the
 * current index and the currently rendered focusable list.
 */
export function wrapFocusIndex(
  currentIndex: number,
  direction: 1 | -1,
  count: number,
): number {
  if (count <= 0) return -1;
  if (currentIndex < 0) return direction > 0 ? 0 : count - 1;
  return (currentIndex + direction + count) % count;
}
