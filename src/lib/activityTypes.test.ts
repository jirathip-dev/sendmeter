import { describe, expect, it } from "vitest";
import { ACTIVITY_COLORS, activityColor } from "./activityTypes";

describe("activity colors", () => {
  it("gives routine sessions a distinct known color", () => {
    expect(ACTIVITY_COLORS.routine).toBeDefined();
    expect(activityColor("routine")).toBe(ACTIVITY_COLORS.routine);
    expect(activityColor("routine")).not.toBe(activityColor("unknown-session-type"));
  });

  it("keeps routine visually distinguishable from antagonist", () => {
    expect(ACTIVITY_COLORS.routine).not.toBe(ACTIVITY_COLORS.antagonist);
  });

  it("assigns every activity a unique color", () => {
    const values = Object.values(ACTIVITY_COLORS);
    expect(new Set(values).size).toBe(values.length);
  });
});
