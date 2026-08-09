import { describe, expect, it } from "vitest";
import {
  clientYToChartCoordinate,
  clientXToChartCoordinate,
  nearestDatumFromClientPoint,
  nearestDatumFromClientX,
  nearestDatumFromClientY,
  nearestDatumIndex2D,
  nearestDatumIndex,
} from "./chartInteraction";

describe("chart-level datum ownership", () => {
  it("chooses the nearest datum and resolves ties to the earlier datum", () => {
    expect(nearestDatumIndex([10, 30, 50], 42)).toBe(2);
    expect(nearestDatumIndex([10, 30, 50], 40)).toBe(1);
  });

  it("handles edge coordinates without changing datum order", () => {
    expect(nearestDatumIndex([10, 30, 50], -100)).toBe(0);
    expect(nearestDatumIndex([10, 30, 50], 100)).toBe(2);
    expect(nearestDatumIndex([], 10)).toBeNull();
  });

  it("maps CSS pixels into the chart coordinate system", () => {
    expect(clientXToChartCoordinate(150, { left: 50, width: 200 }, 300)).toBe(150);
    expect(nearestDatumFromClientX([30, 150, 270], 145, { left: 0, width: 300 }, 300)).toBe(1);
  });

  it("maps vertical CSS pixels and chooses the nearest vertical datum", () => {
    expect(clientYToChartCoordinate(150, { top: 50, height: 200 }, 300)).toBe(150);
    expect(nearestDatumFromClientY([10, 30, 50], 30, { top: 0, height: 300 }, 300)).toBe(1);
  });

  it("chooses the nearest point in a grid with stable tie ownership", () => {
    expect(nearestDatumIndex2D([{ x: 0, y: 0 }, { x: 10, y: 10 }], { x: 5, y: 5 })).toBe(0);
    expect(
      nearestDatumFromClientPoint(
        [{ x: 1, y: 1 }, { x: 9, y: 5 }],
        { x: 85, y: 50 },
        { left: 5, top: 10, width: 100, height: 50 },
        { width: 10, height: 5 },
      ),
    ).toBe(1);
  });
});
