import { describe, expect, it } from "vitest";
import { wrapFocusIndex } from "./sheetFocus";

describe("wrapFocusIndex", () => {
  it("wraps forward and backward within a dialog", () => {
    expect(wrapFocusIndex(0, 1, 3)).toBe(1);
    expect(wrapFocusIndex(2, 1, 3)).toBe(0);
    expect(wrapFocusIndex(0, -1, 3)).toBe(2);
    expect(wrapFocusIndex(2, -1, 3)).toBe(1);
  });

  it("chooses the first or last item when focus came from outside", () => {
    expect(wrapFocusIndex(-1, 1, 2)).toBe(0);
    expect(wrapFocusIndex(-1, -1, 2)).toBe(1);
    expect(wrapFocusIndex(-1, 1, 0)).toBe(-1);
  });
});
