import { describe, expect, it, vi } from "vitest";
import { appendUniqueById, claimManualAttempt, claimManualSession } from "./manualForceSubmission";

describe("manual force submission claims", () => {
  it("claims before async work and reuses the attempt id after a released retry", () => {
    const ids = new Map<string, string>();
    const claimed = new Set<string>();
    const makeId = vi.fn(() => "stable-id");
    expect(claimManualAttempt("1:1:left", ids, claimed, makeId)).toBe("stable-id");
    expect(claimManualAttempt("1:1:left", ids, claimed, makeId)).toBeNull();
    claimed.delete("1:1:left");
    expect(claimManualAttempt("1:1:left", ids, claimed, makeId)).toBe("stable-id");
    expect(makeId).toHaveBeenCalledTimes(1);
  });
  it("allows only one session submission per group claim", () => {
    const claimed = new Set<string>();
    expect(claimManualSession("group", claimed)).toBe(true);
    expect(claimManualSession("group", claimed)).toBe(false);
  });
  it("deduplicates repeated storage-full retries by stable id", () => {
    const item = { id: "stable" };
    expect(appendUniqueById(appendUniqueById([], item), item)).toEqual([item]);
  });
});
