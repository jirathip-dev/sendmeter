import { describe, expect, it } from "vitest";
import {
  armedHandsFreeForce,
  handsFreeForceAtInactiveStatus,
  idleHandsFreeForce,
  rearmedHandsFreeForce,
  stepHandsFreeForce,
  type HandsFreeForceConfig,
  type HandsFreeForceState,
} from "./handsFreeForce";

const CONFIG: HandsFreeForceConfig = {
  startKg: 2,
  stopKg: 1,
  startStableMs: 600,
  stopGraceMs: 1_500,
};

function step(state: HandsFreeForceState, atMs: number, kg: number) {
  return stepHandsFreeForce(state, { atMs, kg }, CONFIG);
}

describe("hands-free Force control (#400)", () => {
  it("preserves the synchronous Arm claim through an intermediate connected render", () => {
    const armed = armedHandsFreeForce();
    expect(handsFreeForceAtInactiveStatus(armed, "connected")).toBe(armed);
    expect(handsFreeForceAtInactiveStatus(armed, "idle")).toEqual({ phase: "idle" });
    expect(
      handsFreeForceAtInactiveStatus({ phase: "recording", belowSinceMs: null }, "connected"),
    ).toEqual({ phase: "idle" });
  });

  it("requires continuous load above the start threshold", () => {
    let state = armedHandsFreeForce();
    ({ state } = step(state, 0, 2.1));
    ({ state } = step(state, 500, 2.3));
    expect(step(state, 599, 3).action).toBeNull();

    // One noisy dip resets the whole stable window.
    ({ state } = step(state, 599, 1.9));
    ({ state } = step(state, 700, 2.2));
    expect(step(state, 1_299, 2.2).action).toBeNull();
    expect(step(state, 1_300, 2.2)).toEqual({
      state: { phase: "recording", belowSinceMs: null },
      action: "start",
    });
  });

  it("requires slack before a post-save re-arm can recognize another pull", () => {
    let state = rearmedHandsFreeForce();
    ({ state } = step(state, 0, 35));
    expect(step(state, 10_000, 35)).toEqual({
      state: { phase: "waitingForSlack" },
      action: null,
    });

    ({ state } = step(state, 10_100, 0.5));
    expect(state).toEqual({ phase: "armed", aboveSinceMs: null });
    ({ state } = step(state, 10_200, 3));
    expect(step(state, 10_800, 3)).toEqual({
      state: { phase: "recording", belowSinceMs: null },
      action: "start",
    });
  });

  it("#681 re-arms through waitingForSlack: release edge arms, then a held pull records", () => {
    let state = rearmedHandsFreeForce();
    expect(state).toEqual({ phase: "waitingForSlack" });

    // A fresh pull before slack is ignored — it must not arm mid-load.
    expect(step(state, 0, 35)).toEqual({
      state: { phase: "waitingForSlack" },
      action: null,
    });
    expect(step(state, 10_000, 35)).toEqual({
      state: { phase: "waitingForSlack" },
      action: null,
    });

    // The release-to-slack edge (at/below stopKg) arms.
    ({ state } = step(state, 10_100, 0.5));
    expect(state).toEqual({ phase: "armed", aboveSinceMs: null });

    // The next pull held startStableMs records.
    ({ state } = step(state, 10_200, 3));
    expect(step(state, 10_800, 3)).toEqual({
      state: { phase: "recording", belowSinceMs: null },
      action: "start",
    });
  });

  it("#681 phantom guard: a continuous load spanning a save never produces a second rep", () => {
    let state = rearmedHandsFreeForce();
    expect(state).toEqual({ phase: "waitingForSlack" });

    // The same continuous load (never dipping to stopKg) spanning the save and
    // well past startStableMs stays waitingForSlack — never arms.
    for (let atMs = 0; atMs <= 60_000; atMs += 500) {
      const stepped = step(state, atMs, 35);
      state = stepped.state;
      expect(stepped.action).toBeNull();
    }
    expect(state).toEqual({ phase: "waitingForSlack" });

    // Only a genuine release arms, then the pull records.
    ({ state } = step(state, 60_500, 0.5));
    expect(state).toEqual({ phase: "armed", aboveSinceMs: null });
    ({ state } = step(state, 60_600, 3));
    expect(step(state, 61_200, 3).action).toBe("start");
  });

  it("uses a lower release threshold and ignores brief force dips", () => {
    let state: HandsFreeForceState = { phase: "recording", belowSinceMs: null };
    ({ state } = step(state, 0, 0.8));
    ({ state } = step(state, 1_000, 0.7));
    expect(step(state, 1_499, 0).action).toBeNull();

    // Recovering above the stop threshold cancels the pending auto-stop.
    ({ state } = step(state, 1_200, 1.1));
    expect(state).toEqual({ phase: "recording", belowSinceMs: null });
    ({ state } = step(state, 2_000, 0.5));
    expect(step(state, 3_499, 0).action).toBeNull();
    expect(step(state, 3_500, 0)).toEqual({
      state: { phase: "stopping" },
      action: "stop",
    });
  });

  it("claims Start and Stop exactly once before caller async work", () => {
    let result = step({ phase: "armed", aboveSinceMs: 0 }, 600, 5);
    expect(result.action).toBe("start");
    expect(step(result.state, 601, 5).action).toBeNull();

    result = step({ phase: "recording", belowSinceMs: 0 }, 1_500, 0);
    expect(result.action).toBe("stop");
    expect(step(result.state, 1_501, 0).action).toBeNull();
  });

  it("recovers safely when a device timestamp moves backwards", () => {
    let result = step({ phase: "armed", aboveSinceMs: 500 }, 100, 3);
    expect(result.state).toEqual({ phase: "armed", aboveSinceMs: 100 });
    result = step({ phase: "recording", belowSinceMs: 500 }, 100, 0);
    expect(result.state).toEqual({ phase: "recording", belowSinceMs: 100 });
  });

  it("does nothing while idle", () => {
    expect(step(idleHandsFreeForce(), 10_000, 50)).toEqual({
      state: { phase: "idle" },
      action: null,
    });
  });
});
