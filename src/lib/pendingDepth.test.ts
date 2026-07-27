import { describe, it, expect } from "vitest";
import { phoneQueueLine } from "./pendingDepth";

describe("phoneQueueLine", () => {
  it("is null for zero", () => {
    expect(phoneQueueLine(0)).toBeNull();
  });

  it("is null for an unknown (not-yet-loaded) count", () => {
    expect(phoneQueueLine(null)).toBeNull();
  });

  it("is null for a negative count (defensive — should never happen)", () => {
    expect(phoneQueueLine(-1)).toBeNull();
  });

  it("renders singular for exactly one", () => {
    expect(phoneQueueLine(1)).toEqual({
      text: "1 recording pending sync",
      tone: "muted",
    });
  });

  it("renders plural for more than one", () => {
    expect(phoneQueueLine(3)).toEqual({
      text: "3 recordings pending sync",
      tone: "muted",
    });
  });

  it("is always muted — never escalates to a warning tone", () => {
    expect(phoneQueueLine(500)?.tone).toBe("muted");
  });
});
