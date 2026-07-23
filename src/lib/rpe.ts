const MIN_RPE = 1;
const MAX_RPE = 10;
const GRID_EPSILON = 1e-9;

/// Step an RPE value by half a point, snapping onto the 0.5 grid first.
/// Auto-tracked sessions save RPE at 0.1 precision (e.g. 5.7), so a bare
/// +/- 0.5 stepper permanently misses the grid (5.7 -> 5.2 -> 4.7 ...).
/// Off-grid values instead snap to the NEAREST half-point in the step
/// direction (5.7, +1 -> 6.0; 5.7, -1 -> 5.5); on-grid values step a full
/// 0.5 as before. Result is clamped to [1, 10] and rounded to 1 decimal to
/// eliminate float drift (e.g. 4.6999999999999).
export function stepRpe(current: number, dir: 1 | -1): number {
  const scaled = current * 2;
  const onGrid = Math.abs(scaled - Math.round(scaled)) < GRID_EPSILON;

  const next = onGrid
    ? current + dir * 0.5
    : dir > 0
      ? Math.ceil(scaled) / 2
      : Math.floor(scaled) / 2;

  const clamped = Math.min(MAX_RPE, Math.max(MIN_RPE, next));
  return Math.round(clamped * 10) / 10;
}
