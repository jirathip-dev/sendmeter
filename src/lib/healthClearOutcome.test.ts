import { describe, expect, it } from "vitest";
import { healthClearOutcome, resolveHealthClearResult } from "./healthClearOutcome";

/// #494 (N4) / review finding F2. Two wrong expressions this pins against:
/// - pre-fix `!resynced` unconditionally: a user with zero prior health rows
///   whose rebuild also finds nothing (`deletedCount: 0, resynced: false`)
///   computes "failed" — the permanent amber banner + a "run it again" remedy
///   that fails every time.
/// - the FIRST attempt at this fix, `deletedCount > 0` as the only failure
///   condition: the same `(0, false)` input now fell into the SUCCESS
///   branch — wrong in the other direction, since `deletedCount === 0` does
///   not distinguish "history was genuinely empty" from "HealthKit access
///   is denied" (a denied user also has zero rows). That version claimed a
///   resync was happening when it wasn't, on the app's one irreversible
///   action.
/// The correct shape is three outcomes: `(0, false)` must be neither
/// "failed" nor "resynced" — it's a distinct "nothingToClear" that must not
/// promise a resync and must not tell the user to retry a remedy that can't
/// fix a denied permission either.
describe("healthClearOutcome (#494, N4 / F2)", () => {
  it("is 'nothingToClear' — not 'failed' and not 'resynced' — when nothing existed and nothing was rebuilt", () => {
    expect(healthClearOutcome(0, false)).toBe("nothingToClear");
  });

  it("is 'failed' when real history existed and the rebuild came back empty", () => {
    expect(healthClearOutcome(5, false)).toBe("failed");
  });

  it("is always 'resynced' when the resync actually succeeded, regardless of count", () => {
    expect(healthClearOutcome(0, true)).toBe("resynced");
    expect(healthClearOutcome(5, true)).toBe("resynced");
  });
});

/// #494 (N4) / review finding F4: `AccountSheet.runClearHealth` — the
/// actual call site where `deleteHealthMetrics`'/`resyncHealthHistory`'s
/// return values get turned into what the user sees — had no test at all.
/// `resolveHealthClearResult` IS that wiring (runClearHealth calls it
/// verbatim), so this suite is what closes that gap: it exercises the exact
/// two-argument shape the real call site passes, not just the inner
/// classification.
describe("resolveHealthClearResult (#494, N4 / F2 / F4)", () => {
  it("nothingToClear: does not promise a resync and does not tell the user to retry", () => {
    const { outcome, toast } = resolveHealthClearResult(0, false);
    expect(outcome).toBe("nothingToClear");
    // Must not contain either of the other two branches' claims — a resync
    // that isn't happening, or a "run it again" remedy that can't fix a
    // denied HealthKit permission (the exact scenario F2 reproduced).
    expect(toast).not.toMatch(/resyncing/i);
    expect(toast).not.toMatch(/run clear.*resync again/i);
  });

  it("failed: keeps the real-failure toast when data actually existed and the rebuild came back empty", () => {
    const { outcome, toast } = resolveHealthClearResult(5, false);
    expect(outcome).toBe("failed");
    expect(toast).toMatch(/resync failed/i);
  });

  it("resynced: keeps the success toast when the resync actually succeeded", () => {
    const { outcome, toast } = resolveHealthClearResult(5, true);
    expect(outcome).toBe("resynced");
    expect(toast).toMatch(/resyncing/i);
  });
});
