import { describe, expect, it } from "vitest";
import {
  disconnectNeedsConfirm,
  PREPARE_S,
  prepRemainingS,
  startsWithCountdown,
} from "./forcePrepare";
import type { TindeqPreset } from "../types";

/// #312 — "Force 5s get-ready countdown does nothing (free hold only)".
///
/// ForceFullscreen (the only consumer of these two functions) renders through
/// `createPortal(..., document.body)` unconditionally, and this repo has no
/// jsdom/testing-library configured (vitest's default environment is plain
/// Node) — so the component can't be mounted or clicked here, not even via
/// `renderToStaticMarkup` (which every *.test.tsx in src/components/ uses
/// instead of a live DOM: it still needs `document` to exist for the portal
/// target, and none does in this environment). The same situation came up in
/// useTindeq.ts (an effect-driven hook that can't be exercised via a render
/// either): `shouldSalvageOnUnmount` was pulled out as a pure, dependency-free
/// gate and tested directly (see useTindeq.test.ts). This module is the same
/// move for the free-hold countdown — ForceFullscreen wires these two
/// functions straight into its click handler and its countdown-tick effect
/// with no extra branching, so covering them here covers the actual bug.

function preset(over: Partial<TindeqPreset> = {}): TindeqPreset {
  return {
    id: "p1",
    name: "Max hangs",
    holdS: 10,
    holdsS: null,
    reps: 3,
    sets: 3,
    restRepsS: 60,
    restSetsS: 180,
    targetKg: null,
    targetPct: null,
    pctBasis: "pr",
    pctStep: 0,
    targetCurve: false,
    alternateSides: false,
    ...over,
  };
}

describe("startsWithCountdown", () => {
  it("a free hold with the checkbox on begins the local countdown", () => {
    expect(startsWithCountdown(null, true)).toBe(true);
  });

  it("a free hold with the checkbox off starts immediately — unchanged regression", () => {
    expect(startsWithCountdown(null, false)).toBe(false);
  });

  it("a guided run NEVER begins the local countdown, checkbox on or off — its own timeline already has a prepare segment", () => {
    expect(startsWithCountdown(preset(), true)).toBe(false);
    expect(startsWithCountdown(preset(), false)).toBe(false);
  });
});

describe("prepRemainingS", () => {
  it("is null when no countdown is running", () => {
    expect(prepRemainingS(null, Date.now())).toBe(null);
  });

  it("starts at the full window the instant the countdown begins", () => {
    const t0 = 1_000_000;
    expect(prepRemainingS(t0, t0)).toBe(PREPARE_S);
  });

  it("counts down as wall-clock time passes", () => {
    const t0 = 1_000_000;
    expect(prepRemainingS(t0, t0 + 2000)).toBe(PREPARE_S - 2);
  });

  it("reaches exactly 0 at the end of the window — the signal the component fires onStart on", () => {
    const t0 = 1_000_000;
    expect(prepRemainingS(t0, t0 + PREPARE_S * 1000)).toBe(0);
  });

  it("clamps at 0 rather than going negative past the window", () => {
    const t0 = 1_000_000;
    expect(prepRemainingS(t0, t0 + 9000)).toBe(0);
  });

  it("honors a custom window length", () => {
    const t0 = 1_000_000;
    expect(prepRemainingS(t0, t0 + 1000, 3)).toBe(2);
  });
});

describe("the free-hold countdown end to end, in pure-logic terms", () => {
  // This is the exact scenario from the bug report: a free hold (no preset,
  // no armed zone) with "5s get-ready countdown" checked. Before the fix,
  // checking the box did nothing — Start measured immediately. The component
  // wires these two functions together as: on tap, `startsWithCountdown`
  // decides whether to stash `Date.now()` instead of calling onStart; an
  // effect then calls onStart only once `prepRemainingS` reaches 0.
  it("does not signal 'done' the instant Start is tapped — the whole point of the fix", () => {
    const startedMs = Date.now();
    expect(startsWithCountdown(null, true)).toBe(true);
    const remaining = prepRemainingS(startedMs, startedMs);
    expect(remaining).toBeGreaterThan(0); // onStart must NOT fire yet
  });

  it("signals 'done' exactly at the 5s mark, so onStart fires exactly once there", () => {
    const startedMs = Date.now();
    expect(prepRemainingS(startedMs, startedMs + 4999)).toBeGreaterThan(0);
    expect(prepRemainingS(startedMs, startedMs + 5000)).toBe(0);
  });

  it("cancelling clears the countdown to the same inert 'null' state as never having started one", () => {
    // The component's Cancel tap is `setPrepStartedMs(null)` — modeled here
    // by feeding `null` back into prepRemainingS, same as before Start was
    // ever tapped. No further tick can ever read a positive remaining from
    // this state, so the fire-effect can never call onStart.
    expect(prepRemainingS(null, Date.now() + 100_000)).toBe(null);
  });

  it("a guided run with the checkbox on skips the local countdown entirely — it starts immediately, its own timeline supplies GET READY", () => {
    expect(startsWithCountdown(preset(), true)).toBe(false);
  });
});

describe("disconnectNeedsConfirm (#486)", () => {
  it("requires confirmation while measuring — the max-effort-rep case the bug report describes", () => {
    expect(disconnectNeedsConfirm({ measuring: true, armed: false, counting: false })).toBe(true);
  });

  it("requires confirmation while armed (hands-free, waiting for the pull to cross threshold)", () => {
    expect(disconnectNeedsConfirm({ measuring: false, armed: true, counting: false })).toBe(true);
  });

  it("requires confirmation during the free-hold get-ready countdown", () => {
    expect(disconnectNeedsConfirm({ measuring: false, armed: false, counting: true })).toBe(true);
  });

  it("does NOT require confirmation at idle — matches Tare/setup-guide staying enabled there", () => {
    expect(disconnectNeedsConfirm({ measuring: false, armed: false, counting: false })).toBe(false);
  });
});
