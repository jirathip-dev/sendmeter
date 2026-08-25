import { describe, expect, it } from "vitest";
import {
  FOREGROUND_RELAY_DEDUPE_MS,
  foregroundRelayNow,
  setForegroundRelayClockForTest,
  shouldStartForegroundRelay,
} from "./foregroundRelay";

/// #612 review F1/F2/N1: the dedupe is a PURE time policy, so every
/// interleaving the in-flight guard mishandled is pinned here with explicit
/// clocks — no timers, no renderer. `useAuth` is reduced to recording
/// `lastStartedAt` and consulting this predicate (see useAuth.test.tsx for
/// the hook-level integration cases).

describe("shouldStartForegroundRelay (#612)", () => {
  it("starts the first pass of the launch — the null sentinel, whatever the clock reads", () => {
    // `lastStartedAt` is `null` before any pass. The sentinel must not depend
    // on the clock value: `performance.now()` is only a few hundred ms after
    // page load, so a `0` sentinel would wrongly suppress the first pass
    // (review N1).
    expect(shouldStartForegroundRelay(50, null)).toBe(true);
    expect(shouldStartForegroundRelay(1_000_000, null)).toBe(true);
  });

  it("suppresses a second pass within the window, even long after the first read resolved", () => {
    // F1's missed interleaving: first pass starts at t=100, resolves in a few
    // microtasks, and the second signal arrives 200ms later — still inside
    // the window, so it must be suppressed regardless of settlement timing.
    expect(shouldStartForegroundRelay(100, 100)).toBe(false);
    expect(shouldStartForegroundRelay(1_000_300, 1_000_000)).toBe(false);
  });

  it("allows a pass exactly at the window boundary", () => {
    expect(
      shouldStartForegroundRelay(1_001_000, 1_000_000, FOREGROUND_RELAY_DEDUPE_MS),
    ).toBe(true);
  });

  it("allows a pass after the window, even while the prior read is still pending", () => {
    // F2's missed interleaving: the first read never settles (hung refresh
    // fetch). The window is settlement-agnostic, so a later signal still
    // starts a pass — a hung read cannot latch the relay off.
    expect(
      shouldStartForegroundRelay(1_010_000, 1_000_000, FOREGROUND_RELAY_DEDUPE_MS),
    ).toBe(true);
  });

  it("a rejection changes nothing — the policy has no promise state", () => {
    // The predicate takes only (now, lastStartedAt, window); how the prior
    // pass ended (resolved null, resolved session, rejected, hung) is
    // irrelevant to the next decision. Same clock state, same answer.
    expect(shouldStartForegroundRelay(1_000_500, 1_000_000)).toBe(false);
    expect(shouldStartForegroundRelay(1_001_000, 1_000_000)).toBe(true);
  });

  it("never starts a pass on a clock that went backwards (skew guard)", () => {
    // A monotonic caller cannot produce this, but the predicate still guards
    // it so a buggy clock can't reopen the window.
    expect(shouldStartForegroundRelay(1_000_000, 1_000_500)).toBe(false);
  });
});

describe("the monotonic foreground clock (review N1)", () => {
  it("defaults to performance.now() and is replaceable through the test seam", () => {
    expect(typeof foregroundRelayNow()).toBe("number");
    setForegroundRelayClockForTest(() => 42);
    try {
      expect(foregroundRelayNow()).toBe(42);
    } finally {
      setForegroundRelayClockForTest(() => performance.now());
    }
  });
});
