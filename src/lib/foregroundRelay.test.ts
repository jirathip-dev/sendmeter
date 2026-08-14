import { describe, expect, it } from "vitest";
import {
  FOREGROUND_RELAY_DEDUPE_MS,
  shouldStartForegroundRelay,
} from "./foregroundRelay";

/// #612 review F1/F2: the dedupe is a PURE time policy, so every
/// interleaving the in-flight guard mishandled is pinned here with explicit
/// clocks — no timers, no renderer. `useAuth` is reduced to recording
/// `lastStartedAt` and consulting this predicate (see useAuth.test.tsx for
/// the hook-level integration cases).

describe("shouldStartForegroundRelay (#612)", () => {
  it("starts the first pass of the launch — no previous start", () => {
    // `lastStartedAt` is 0 before any pass; real epoch times are ≫ window.
    expect(shouldStartForegroundRelay(1_000_000, 0)).toBe(true);
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

  it("never starts a pass on a clock that went backwards (skew)", () => {
    expect(shouldStartForegroundRelay(1_000_000, 1_000_500)).toBe(false);
  });
});
