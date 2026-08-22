import { describe, expect, it } from "vitest";
import {
  armedHandsFreeForce,
  handsFreeForceAtInactiveStatus,
  idleHandsFreeForce,
  rearmedHandsFreeForce,
  recordingVerdict,
  stepHandsFreeForce,
  type HandsFreeForceConfig,
  type HandsFreeForceState,
} from "./handsFreeForce";

const CONFIG: HandsFreeForceConfig = {
  startKg: 2,
  stopKg: 1,
  startStableMs: 600,
  stopGraceMs: 1_500,
  minPeakKg: 3,
  minDurationMs: 1_500,
  flatlineWindowMs: 30_000,
  flatlineBandKg: 0.25,
};

function step(state: HandsFreeForceState, atMs: number, kg: number) {
  return stepHandsFreeForce(state, { atMs, kg }, CONFIG);
}

function flatWatch(sinceMs: number, kg: number) {
  return { sinceMs, minKg: kg, maxKg: kg };
}

describe("hands-free Force control (#400)", () => {
  it("preserves the synchronous Arm claim through an intermediate connected render", () => {
    const armed = armedHandsFreeForce();
    expect(handsFreeForceAtInactiveStatus(armed, "connected")).toBe(armed);
    expect(handsFreeForceAtInactiveStatus(armed, "idle")).toEqual({ phase: "idle" });
    expect(
      handsFreeForceAtInactiveStatus(
        { phase: "recording", belowSinceMs: null, flatWatch: null },
        "connected",
      ),
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
      state: {
        phase: "recording",
        belowSinceMs: null,
        flatWatch: flatWatch(1_300, 2.2),
      },
      action: "start",
      staticLoadEndMs: null,
    });
  });

  it("requires slack before a post-save re-arm can recognize another pull", () => {
    let state = rearmedHandsFreeForce();
    ({ state } = step(state, 0, 35));
    expect(step(state, 10_000, 35)).toEqual({
      state: { phase: "waitingForSlack" },
      action: null,
      staticLoadEndMs: null,
    });

    ({ state } = step(state, 10_100, 0.5));
    expect(state).toEqual({ phase: "armed", aboveSinceMs: null });
    ({ state } = step(state, 10_200, 3));
    expect(step(state, 10_800, 3)).toEqual({
      state: {
        phase: "recording",
        belowSinceMs: null,
        flatWatch: flatWatch(10_800, 3),
      },
      action: "start",
      staticLoadEndMs: null,
    });
  });

  it("#681 re-arms through waitingForSlack: release edge arms, then a held pull records", () => {
    let state = rearmedHandsFreeForce();
    expect(state).toEqual({ phase: "waitingForSlack" });

    // A fresh pull before slack is ignored — it must not arm mid-load.
    expect(step(state, 0, 35)).toEqual({
      state: { phase: "waitingForSlack" },
      action: null,
      staticLoadEndMs: null,
    });
    expect(step(state, 10_000, 35)).toEqual({
      state: { phase: "waitingForSlack" },
      action: null,
      staticLoadEndMs: null,
    });

    // The release-to-slack edge (at/below stopKg) arms.
    ({ state } = step(state, 10_100, 0.5));
    expect(state).toEqual({ phase: "armed", aboveSinceMs: null });

    // The next pull held startStableMs records.
    ({ state } = step(state, 10_200, 3));
    expect(step(state, 10_800, 3)).toEqual({
      state: {
        phase: "recording",
        belowSinceMs: null,
        flatWatch: flatWatch(10_800, 3),
      },
      action: "start",
      staticLoadEndMs: null,
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
    let state: HandsFreeForceState = {
      phase: "recording",
      belowSinceMs: null,
      flatWatch: null,
    };
    ({ state } = step(state, 0, 0.8));
    ({ state } = step(state, 1_000, 0.7));
    expect(step(state, 1_499, 0).action).toBeNull();

    // Recovering above the stop threshold cancels the pending auto-stop.
    ({ state } = step(state, 1_200, 1.1));
    expect(state).toEqual({
      phase: "recording",
      belowSinceMs: null,
      flatWatch: flatWatch(1_200, 1.1),
    });
    ({ state } = step(state, 2_000, 0.5));
    expect(step(state, 3_499, 0).action).toBeNull();
    expect(step(state, 3_500, 0)).toEqual({
      state: { phase: "stopping" },
      action: "stop",
      staticLoadEndMs: null,
    });
  });

  it("claims Start and Stop exactly once before caller async work", () => {
    let result = step({ phase: "armed", aboveSinceMs: 0 }, 600, 5);
    expect(result.action).toBe("start");
    expect(step(result.state, 601, 5).action).toBeNull();

    result = step(
      { phase: "recording", belowSinceMs: 0, flatWatch: null },
      1_500,
      0,
    );
    expect(result.action).toBe("stop");
    expect(step(result.state, 1_501, 0).action).toBeNull();
  });

  it("recovers safely when a device timestamp moves backwards", () => {
    let result = step({ phase: "armed", aboveSinceMs: 500 }, 100, 3);
    expect(result.state).toEqual({ phase: "armed", aboveSinceMs: 100 });
    result = step(
      { phase: "recording", belowSinceMs: 500, flatWatch: null },
      100,
      0,
    );
    expect(result.state).toEqual({
      phase: "recording",
      belowSinceMs: 100,
      flatWatch: flatWatch(100, 0),
    });
  });

  it("does nothing while idle", () => {
    expect(step(idleHandsFreeForce(), 10_000, 50)).toEqual({
      state: { phase: "idle" },
      action: null,
      staticLoadEndMs: null,
    });
  });
});

describe("hands-free Force guards (#682)", () => {
  it("#682: recording peaking at 2.9 kg is discarded; 3.1 kg persists", () => {
    expect(recordingVerdict(2.9, 10_000, CONFIG)).toEqual({ discard: "belowMinPeak" });
    expect(recordingVerdict(3.1, 10_000, CONFIG)).toBe("persist");
  });

  it("#682: recording lasting 1.4 s is discarded; 1.6 s persists", () => {
    expect(recordingVerdict(10, 1_400, CONFIG)).toEqual({ discard: "belowMinDuration" });
    expect(recordingVerdict(10, 1_600, CONFIG)).toBe("persist");
  });

  it("#682: 30 s flat inside the band terminates as static load and trims to the flat-window start", () => {
    let state = armedHandsFreeForce();
    state = step(state, 0, 3).state;
    const start = step(state, 600, 3);
    expect(start.action).toBe("start");
    state = start.state;
    let result = start;
    for (let atMs = 700; atMs <= 30_600; atMs += 100) {
      result = step(state, atMs, 3);
      state = result.state;
      if (result.action === "stop") break;
    }
    expect(result.action).toBe("stop");
    // The flat window began at the sample that claimed Start (600), not at
    // termination (30_600) — the trim cuts the persistent flat tail.
    expect(result.staticLoadEndMs).toBe(600);
  });

  it("#682: 29 s flat then a 2 kg excursion does not terminate and resets the window", () => {
    let state = armedHandsFreeForce();
    state = step(state, 0, 3).state;
    const start = step(state, 600, 3);
    expect(start.action).toBe("start");
    state = start.state;
    let result;
    // 29 s of flat load inside the band — no termination yet.
    for (let atMs = 700; atMs <= 29_600; atMs += 100) {
      result = step(state, atMs, 3);
      state = result.state;
      expect(result.action).toBeNull();
    }
    // The 2 kg excursion breaks the 0.25 kg band → the window resets to it.
    result = step(state, 29_700, 5);
    state = result.state;
    expect(result.action).toBeNull();
    expect(state.phase).toBe("recording");
    if (state.phase === "recording") {
      expect(state.flatWatch).toEqual(flatWatch(29_700, 5));
    }
    // The new window has only just started — still no termination.
    result = step(state, 30_100, 5);
    expect(result.action).toBeNull();
  });

  it("#682: a static-load-terminated recording peaking below 3 kg is discarded by Guard 1", () => {
    let state = armedHandsFreeForce();
    state = step(state, 0, 3).state;
    const start = step(state, 600, 2.9);
    expect(start.action).toBe("start");
    state = start.state;
    let peak = 0;
    let result = start;
    for (let atMs = 700; atMs <= 30_600; atMs += 100) {
      result = step(state, atMs, 2.9);
      state = result.state;
      peak = Math.max(peak, 2.9);
      if (result.action === "stop") break;
    }
    expect(result.action).toBe("stop");
    expect(result.staticLoadEndMs).toBe(600);
    // Guard 1 evaluates the terminated recording LAST — a flat-terminated rep
    // peaking below the persist threshold is discarded, never persisted.
    expect(recordingVerdict(peak, 10_000, CONFIG)).toEqual({ discard: "belowMinPeak" });
  });

  it("#682: a discarded rep is never reported as queued", () => {
    // The persist funnel gates on the pure verdict. A below-min-peak rep is a
    // discard, so the funnel must not enqueue it or report it as saved.
    const verdict = recordingVerdict(2.9, 10_000, CONFIG);
    expect(verdict).toEqual({ discard: "belowMinPeak" });
    // The complement: a qualifying rep persists.
    expect(recordingVerdict(3.1, 10_000, CONFIG)).toBe("persist");
  });
});
