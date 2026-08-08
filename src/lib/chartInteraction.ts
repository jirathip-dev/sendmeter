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

export function clientYToChartCoordinate(
  clientY: number,
  rect: { top: number; height: number },
  chartHeight: number,
): number {
  if (!Number.isFinite(clientY) || !Number.isFinite(rect.height) || rect.height <= 0) {
    return 0;
  }
  return ((clientY - rect.top) / rect.height) * chartHeight;
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

export function nearestDatumFromClientY(
  positions: readonly number[],
  clientY: number,
  rect: { top: number; height: number },
  chartHeight: number,
): number | null {
  return nearestDatumIndex(
    positions,
    clientYToChartCoordinate(clientY, rect, chartHeight),
  );
}

export interface ChartPoint2D {
  x: number;
  y: number;
}

/** Deterministic nearest-point selection for a dense 2D surface. */
export function nearestDatumIndex2D(
  positions: readonly ChartPoint2D[],
  coordinate: ChartPoint2D,
): number | null {
  if (positions.length === 0 || !Number.isFinite(coordinate.x) || !Number.isFinite(coordinate.y)) {
    return null;
  }
  let nearest = 0;
  let distance = Number.POSITIVE_INFINITY;
  for (let i = 0; i < positions.length; i += 1) {
    const point = positions[i]!;
    const dx = point.x - coordinate.x;
    const dy = point.y - coordinate.y;
    const nextDistance = dx * dx + dy * dy;
    // Strictly less keeps ties stable and independent from paint/DOM order.
    if (nextDistance < distance) {
      nearest = i;
      distance = nextDistance;
    }
  }
  return nearest;
}

export function nearestDatumFromClientPoint(
  positions: readonly ChartPoint2D[],
  client: { x: number; y: number },
  rect: { left: number; top: number; width: number; height: number },
  chartSize: { width: number; height: number },
): number | null {
  return nearestDatumIndex2D(positions, {
    x: clientXToChartCoordinate(client.x, rect, chartSize.width),
    y: clientYToChartCoordinate(client.y, rect, chartSize.height),
  });
}
