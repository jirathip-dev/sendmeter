import { describe, expect, it } from "vitest";
// Deliberately imported from healthSignature.ts, not healthSync.ts:
// healthSync.ts pulls in repo/health.ts, which instantiates a real Supabase
// client at module scope — this repo's tests are pure-logic-only (see
// CLAUDE.md), so importing through healthSync.ts here would drag Supabase
// into a unit test.
import { healthSignaturesEqual } from "./healthSignature";

// #146: "Health data synced" toast fired on every foreground, even when
// nothing new actually synced — the native plugin always re-upserts the
// biometric columns "locked or not", so a resolved syncNow() call never
// meant "new data landed". `healthSignaturesEqual` is the extracted pure
// comparison (`changed = !healthSignaturesEqual(before, after)`) so this is
// testable without Supabase/Capacitor, per this repo's "pure logic only"
// web-test convention (CLAUDE.md).
describe("healthSignaturesEqual (#146)", () => {
  it("identical signatures (computed_at already excluded upstream) → equal, no toast", () => {
    const sig = JSON.stringify({ hrv_sdnn_ms: 55, resting_hr: 48, readiness: 72 });
    expect(healthSignaturesEqual(sig, sig)).toBe(true);
  });

  it("a biometric field differing between before/after → not equal, toast", () => {
    const before = JSON.stringify({ hrv_sdnn_ms: 55, resting_hr: 48, readiness: 72 });
    const after = JSON.stringify({ hrv_sdnn_ms: 55, resting_hr: 51, readiness: 72 });
    expect(healthSignaturesEqual(before, after)).toBe(false);
  });

  it("no row yet today (before null), first real sync lands data (after set) → not equal, must still toast", () => {
    // The fix must NOT accidentally suppress the first sync of the day.
    const after = JSON.stringify({ hrv_sdnn_ms: 55, resting_hr: 48, readiness: 72 });
    expect(healthSignaturesEqual(null, after)).toBe(false);
  });

  it("no HealthKit data at all, before and after both null → equal, no toast", () => {
    expect(healthSignaturesEqual(null, null)).toBe(true);
  });

  it("a signature fetch failure (undefined) is treated as equal → fails closed, no toast", () => {
    // `undefined` signals the fetch itself threw (network/read error), which
    // is genuinely unknown rather than "definitely different" — fail closed
    // so a comparison failure suppresses the toast instead of risking a
    // false positive. (`recordHealthSync` itself still runs unconditionally
    // in `syncHealthNow`'s try block regardless of this comparison, so the
    // "Last synced Xm ago" line keeps updating — that call is native-gated
    // and out of this pure-logic test's scope per CLAUDE.md.)
    const after = JSON.stringify({ hrv_sdnn_ms: 55, resting_hr: 48, readiness: 72 });
    expect(healthSignaturesEqual(undefined, after)).toBe(true);
    expect(healthSignaturesEqual(after, undefined)).toBe(true);
  });
});
