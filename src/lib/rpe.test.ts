import { describe, expect, it } from "vitest";
import { stepRpe } from "./rpe";

describe("stepRpe (issue #114)", () => {
  it("snaps an off-grid value UP to the nearest half-point when incrementing", () => {
    expect(stepRpe(5.7, 1)).toBe(6.0);
    expect(stepRpe(5.1, 1)).toBe(5.5);
  });

  it("snaps an off-grid value DOWN to the nearest half-point when decrementing", () => {
    expect(stepRpe(5.7, -1)).toBe(5.5);
    expect(stepRpe(5.9, -1)).toBe(5.5);
  });

  it("steps a full 0.5 when already on the grid", () => {
    expect(stepRpe(5.5, 1)).toBe(6.0);
    expect(stepRpe(5.5, -1)).toBe(5.0);
    expect(stepRpe(7, 1)).toBe(7.5);
    expect(stepRpe(7, -1)).toBe(6.5);
  });

  it("clamps to 10 at the top, snapping off-grid values that round past it", () => {
    expect(stepRpe(9.8, 1)).toBe(10);
    expect(stepRpe(10, 1)).toBe(10);
    expect(stepRpe(9.5, 1)).toBe(10);
  });

  it("clamps to 1 at the bottom, snapping off-grid values that round past it", () => {
    expect(stepRpe(1.2, -1)).toBe(1);
    expect(stepRpe(1, -1)).toBe(1);
    expect(stepRpe(1.5, -1)).toBe(1);
  });

  it("never returns more than 1 decimal place (no float drift)", () => {
    let rpe = 5.7;
    for (let i = 0; i < 20; i++) {
      rpe = stepRpe(rpe, 1);
      expect(rpe).toBe(Number(rpe.toFixed(1)));
    }
    rpe = 5.7;
    for (let i = 0; i < 20; i++) {
      rpe = stepRpe(rpe, -1);
      expect(rpe).toBe(Number(rpe.toFixed(1)));
    }
  });

  it("repeated stepping from an auto-tracked reading stays on the 0.5 grid", () => {
    let rpe = 5.7;
    rpe = stepRpe(rpe, 1); // -> 6.0
    rpe = stepRpe(rpe, 1); // -> 6.5
    rpe = stepRpe(rpe, -1); // -> 6.0
    expect(rpe).toBe(6.0);
  });
});
