import { describe, expect, it } from "vitest";
import { shouldDismissSheetGesture } from "./sheetGesture";

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
