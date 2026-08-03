import { describe, expect, it } from "vitest";
import { ACTIVITY_COLORS, activityColor } from "./activityTypes";

describe("activity colors", () => {
  it("gives routine sessions a distinct known color", () => {
    expect(ACTIVITY_COLORS.routine).toBeDefined();
    expect(activityColor("routine")).toBe(ACTIVITY_COLORS.routine);
    expect(activityColor("routine")).not.toBe(activityColor("unknown-session-type"));
  });
});
