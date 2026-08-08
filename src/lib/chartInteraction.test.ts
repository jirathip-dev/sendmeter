import { describe, expect, it } from "vitest";
import {
  clientXToChartCoordinate,
  nearestDatumFromClientX,
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
});
