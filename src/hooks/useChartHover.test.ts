import { describe, it, expect, vi } from "vitest";
import { createOutsideClearTracker } from "./useChartHover";

// #299: on touch there's no hover to clear a tapped point's tooltip, so
// `createOutsideClearTracker` is the pure decision logic that stands in for
// "did this pointerdown land on the point that just claimed it, or somewhere
// else in the app". These cases exercise it directly (node env, no DOM —
// events are just opaque tokens the tracker compares by identity).
describe("createOutsideClearTracker", () => {
  it("does not clear when the window pointerdown is the event the point itself just claimed", () => {
    const clear = vi.fn();
    const tracker = createOutsideClearTracker(clear);
    const ev1 = {};

    tracker.claim(ev1);
    tracker.onWindowPointerDown(ev1);

    expect(clear).not.toHaveBeenCalled();
  });

  it("clears on a pointerdown elsewhere when nothing has been claimed", () => {
    const clear = vi.fn();
    const tracker = createOutsideClearTracker(clear);
    const ev2 = {};

    tracker.onWindowPointerDown(ev2);

    expect(clear).toHaveBeenCalledTimes(1);
  });

  it("a stale claim doesn't shield a later, different tap — clears exactly once, on the new event", () => {
    const clear = vi.fn();
    const tracker = createOutsideClearTracker(clear);
    const ev1 = {};
    const ev2 = {};

    tracker.claim(ev1);
    tracker.onWindowPointerDown(ev1); // own point's tap — no clear
    tracker.onWindowPointerDown(ev2); // a later, unrelated tap — clears

    expect(clear).toHaveBeenCalledTimes(1);
    expect(clear).toHaveBeenLastCalledWith();
  });

  it("re-tapping a new point on the same chart swaps the claim without ever clearing", () => {
    const clear = vi.fn();
    const tracker = createOutsideClearTracker(clear);
    const ev1 = {};
    const ev2 = {};

    tracker.claim(ev1);
    tracker.onWindowPointerDown(ev1);
    tracker.claim(ev2);
    tracker.onWindowPointerDown(ev2);

    expect(clear).not.toHaveBeenCalled();
  });
});
