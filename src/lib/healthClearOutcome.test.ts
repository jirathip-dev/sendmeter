import { describe, expect, it } from "vitest";
import { healthClearFailed } from "./healthClearOutcome";

/// #494 (N4). Before this fix, AccountSheet's `runClearHealth` set
/// `resyncFailed` to `!resynced` unconditionally — that expression is what
/// `healthClearFailed` replaces. This test pins the VALUE it must now
/// produce: on the pre-fix expression, a user with zero prior health rows
/// whose rebuild also finds nothing (`deletedCount: 0, resynced: false`)
/// computes `true` (failed) — the permanent amber banner + a "run it again"
/// remedy that fails every time. Post-fix it must be `false`.
describe("healthClearFailed (#494, N4)", () => {
  it("is NOT a failure when nothing existed before and nothing was rebuilt", () => {
    expect(healthClearFailed(0, false)).toBe(false);
  });

  it("IS a failure when real history existed and the rebuild came back empty", () => {
    expect(healthClearFailed(5, false)).toBe(true);
  });

  it("is never a failure when the resync actually succeeded, regardless of count", () => {
    expect(healthClearFailed(0, true)).toBe(false);
    expect(healthClearFailed(5, true)).toBe(false);
  });
});
