/**
 * Pick the datum nearest to a pointer coordinate.  A single chart-level
 * surface uses this instead of a collection of overlapping per-point hit
 * targets, which keeps ownership deterministic even when points are closer
 * than a touch target.
 */
export function nearestDatumIndex(
  positions: readonly number[],
  coordinate: number,
): number | null {
  if (positions.length === 0 || !Number.isFinite(coordinate)) return null;

  let nearest = 0;
  let distance = Math.abs(positions[0]! - coordinate);
  for (let i = 1; i < positions.length; i += 1) {
    const nextDistance = Math.abs(positions[i]! - coordinate);
    // Strictly less is intentional: ties go to the earlier datum and are
    // therefore stable regardless of DOM order.
    if (nextDistance < distance) {
      nearest = i;
      distance = nextDistance;
    }
  }
  return nearest;
}

export function clientXToChartCoordinate(
  clientX: number,
  rect: { left: number; width: number },
  chartWidth: number,
): number {
  if (!Number.isFinite(clientX) || !Number.isFinite(rect.width) || rect.width <= 0) {
    return 0;
  }
  return ((clientX - rect.left) / rect.width) * chartWidth;
}

export function nearestDatumFromClientX(
  positions: readonly number[],
  clientX: number,
  rect: { left: number; width: number },
  chartWidth: number,
): number | null {
  return nearestDatumIndex(
    positions,
    clientXToChartCoordinate(clientX, rect, chartWidth),
  );
}
