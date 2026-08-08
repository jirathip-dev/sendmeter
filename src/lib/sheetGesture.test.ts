import { describe, expect, it } from "vitest";
import {
  isSheetDragExcludedTarget,
  shouldDismissSheetGesture,
  shouldStartSheetDrag,
} from "./sheetGesture";

const dismissibleGesture = {
  dismissible: true,
  cancelled: false,
};

describe("shouldDismissSheetGesture", () => {
  it("dismisses after the distance threshold even when released slowly", () => {
    expect(
      shouldDismissSheetGesture({
        ...dismissibleGesture,
        distancePx: 100,
        velocityPxPerMs: 0.05,
      }),
    ).toBe(true);
  });

  it("dismisses a deliberate short, fast downward flick", () => {
    expect(
      shouldDismissSheetGesture({
        ...dismissibleGesture,
        distancePx: 40,
        velocityPxPerMs: 0.8,
      }),
    ).toBe(true);
  });

  it("snaps back for small, slow movement and for a cancelled gesture", () => {
    expect(
      shouldDismissSheetGesture({
        ...dismissibleGesture,
        distancePx: 40,
        velocityPxPerMs: 0.2,
      }),
    ).toBe(false);
    expect(
      shouldDismissSheetGesture({
        ...dismissibleGesture,
        distancePx: 10,
        velocityPxPerMs: 2,
      }),
    ).toBe(false);
    expect(
      shouldDismissSheetGesture({
        ...dismissibleGesture,
        cancelled: true,
        distancePx: 140,
        velocityPxPerMs: 1.2,
      }),
    ).toBe(false);
  });

  it("does not dismiss a non-dismissible sheet by distance or velocity", () => {
    expect(
      shouldDismissSheetGesture({
        dismissible: false,
        cancelled: false,
        distancePx: 140,
        velocityPxPerMs: 1.2,
      }),
    ).toBe(false);
  });
});

describe("shouldStartSheetDrag", () => {
  it("requires a downward gesture with clear vertical intent", () => {
    expect(shouldStartSheetDrag({ dx: 0, dy: 8 })).toBe(true);
    expect(shouldStartSheetDrag({ dx: 5, dy: 20 })).toBe(true);
    expect(shouldStartSheetDrag({ dx: 18, dy: 20 })).toBe(false);
    expect(shouldStartSheetDrag({ dx: 0, dy: -20 })).toBe(false);
    expect(shouldStartSheetDrag({ dx: 0, dy: 7 })).toBe(false);
  });
});

describe("isSheetDragExcludedTarget", () => {
  it("protects controls, editable content, and horizontal chart surfaces", () => {
    expect(isSheetDragExcludedTarget({ tagName: "button" })).toBe(true);
    expect(isSheetDragExcludedTarget({ tagName: "input" })).toBe(true);
    expect(isSheetDragExcludedTarget({ contentEditable: true })).toBe(true);
    expect(isSheetDragExcludedTarget({ classes: ["chart-scrub"] })).toBe(true);
    expect(isSheetDragExcludedTarget({ classes: ["sheet-no-drag"] })).toBe(true);
    expect(isSheetDragExcludedTarget({ tagName: "div" })).toBe(false);
  });
});
