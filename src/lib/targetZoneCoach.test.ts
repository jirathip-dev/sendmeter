import { describe, expect, it } from "vitest";
import {
  idleTargetZoneCoach,
  stepTargetZoneCoach,
  targetZoneCoachActive,
  targetZoneAtForce,
  type TargetZoneCoachConfig,
  type TargetZoneCoachInput,
  type TargetZoneCoachState,
} from "./targetZoneCoach";

const CONFIG: TargetZoneCoachConfig = { hysteresisKg: 0.3, dwellMs: 300 };

function input(
  timestampMs: number,
  currentKg: number,
  over: Partial<TargetZoneCoachInput> = {},
): TargetZoneCoachInput {
  return {
    currentKg,
    targetLowKg: 10,
    targetHighKg: 12,
    timestampMs,
    active: true,
    ...over,
  };
}

function step(state: TargetZoneCoachState, timestampMs: number, currentKg: number) {
  return stepTargetZoneCoach(state, input(timestampMs, currentKg), CONFIG);
}

function commitAt(currentKg: number): TargetZoneCoachState {
  let state = idleTargetZoneCoach();
  ({ state } = step(state, 0, currentKg));
  const committed = step(state, 300, currentKg);
  expect(committed.cue).not.toBeNull();
  return committed.state;
}

describe("target-zone coach state machine (#400)", () => {
  it("exposes the immediate visual zone independently from optional coaching", () => {
    expect(targetZoneAtForce(9, 10, 12)).toBe("below");
    expect(targetZoneAtForce(11, 10, 12)).toBe("in-zone");
    expect(targetZoneAtForce(13, 10, 12)).toBe("above");
  });
  it("treats both exact target boundaries as in-zone", () => {
    let low = step(idleTargetZoneCoach(), 0, 10);
    low = step(low.state, 300, 10);
    expect(low).toMatchObject({ state: { zone: "in-zone" }, cue: "in-zone" });

    let high = step(idleTargetZoneCoach(), 0, 12);
    high = step(high.state, 300, 12);
    expect(high).toMatchObject({ state: { zone: "in-zone" }, cue: "in-zone" });
  });

  it("does not chatter when noisy samples cross a committed band edge", () => {
    let state = commitAt(11);
    for (const [at, kg] of [
      [400, 9.8],
      [500, 10.1],
      [600, 9.9],
      [700, 10.2],
      [800, 9.75],
    ] as const) {
      const result = step(state, at, kg);
      state = result.state;
      expect(result.cue).toBeNull();
      expect(state.zone).toBe("in-zone");
    }
  });

  it("requires the full stable dwell before committing a new zone", () => {
    let state = commitAt(11);
    ({ state } = step(state, 400, 12.4));
    expect(step(state, 699, 12.8).cue).toBeNull();
    const committed = step(state, 700, 12.8);
    expect(committed).toMatchObject({ state: { zone: "above" }, cue: "above" });
  });

  it("requires hysteresis clearance before re-entering from below or above", () => {
    let below = commitAt(8);
    expect(step(below, 400, 10.29).state).toMatchObject({
      zone: "below",
      candidateZone: null,
    });
    ({ state: below } = step(below, 500, 10.3));
    expect(step(below, 799, 10.3).cue).toBeNull();
    expect(step(below, 800, 10.3)).toMatchObject({
      state: { zone: "in-zone" },
      cue: "in-zone",
    });

    let above = commitAt(14);
    expect(step(above, 400, 11.71).state).toMatchObject({
      zone: "above",
      candidateZone: null,
    });
    ({ state: above } = step(above, 500, 11.7));
    expect(step(above, 800, 11.7)).toMatchObject({
      state: { zone: "in-zone" },
      cue: "in-zone",
    });
  });

  it("resets its dwell safely when timestamps move backward", () => {
    let state = commitAt(8);
    ({ state } = step(state, 600, 11));
    const rolledBack = step(state, 100, 11);
    expect(rolledBack).toMatchObject({
      state: { zone: "unknown", candidateZone: "in-zone", candidateSinceMs: 100 },
      cue: null,
    });
    expect(step(rolledBack.state, 399, 11).cue).toBeNull();
    expect(step(rolledBack.state, 400, 11).cue).toBe("in-zone");
  });

  it("resets while inactive and requires a fresh dwell on resume", () => {
    const committed = commitAt(11);
    const inactive = stepTargetZoneCoach(committed, input(400, 11, { active: false }), CONFIG);
    expect(inactive).toEqual({ state: idleTargetZoneCoach(), cue: null });

    let resumed = stepTargetZoneCoach(inactive.state, input(1_000, 11), CONFIG);
    expect(resumed.cue).toBeNull();
    resumed = stepTargetZoneCoach(resumed.state, input(1_300, 11), CONFIG);
    expect(resumed.cue).toBe("in-zone");
  });

  it("resets when the target band changes", () => {
    const committed = commitAt(11);
    const changed = stepTargetZoneCoach(
      committed,
      input(400, 11, { targetLowKg: 14, targetHighKg: 16 }),
      CONFIG,
    );
    expect(changed).toMatchObject({
      state: {
        zone: "unknown",
        candidateZone: "below",
        targetLowKg: 14,
        targetHighKg: 16,
      },
      cue: null,
    });
    expect(
      stepTargetZoneCoach(
        changed.state,
        input(700, 11, { targetLowKg: 14, targetHighKg: 16 }),
        CONFIG,
      ).cue,
    ).toBe("below");
  });

  it("claims each cue synchronously and emits it exactly once", () => {
    let result = step(idleTargetZoneCoach(), 0, 8);
    result = step(result.state, 300, 8);
    expect(result.cue).toBe("below");
    expect(step(result.state, 300, 8).cue).toBeNull();
    expect(step(result.state, 301, 8).cue).toBeNull();

    result = step(result.state, 400, 11);
    result = step(result.state, 700, 11);
    expect(result.cue).toBe("in-zone");
    expect(step(result.state, 701, 11).cue).toBeNull();
  });

  it("is neutral for absent, invalid, or non-finite targets and samples", () => {
    const committed = commitAt(11);
    for (const invalid of [
      input(400, 11, { targetLowKg: null }),
      input(400, 11, { targetHighKg: null }),
      input(400, 11, { targetLowKg: 12, targetHighKg: 12 }),
      input(400, Number.NaN),
      input(Number.NaN, 11),
    ]) {
      expect(stepTargetZoneCoach(committed, invalid, CONFIG)).toEqual({
        state: idleTargetZoneCoach(),
        cue: null,
      });
    }
  });
});

describe("Force fullscreen coaching activity gate", () => {
  const base = {
    enabled: true,
    measuring: true,
    hasTarget: true,
    guided: true,
    guidedPhase: "hold" as const,
    paused: false,
  };

  it("coaches a targeted free hold regardless of hands-free control", () => {
    expect(targetZoneCoachActive({ ...base, guided: false, guidedPhase: null })).toBe(true);
  });

  it("coaches only actual guided hold or cadence-movement segments", () => {
    expect(targetZoneCoachActive(base)).toBe(true);
    expect(targetZoneCoachActive({ ...base, guidedPhase: "move" })).toBe(true);
    for (const guidedPhase of ["prepare", "rest", "switch", "setRest"] as const) {
      expect(targetZoneCoachActive({ ...base, guidedPhase })).toBe(false);
    }
    expect(targetZoneCoachActive({ ...base, guidedPhase: null })).toBe(false); // done
  });

  it("stays silent while paused, idle, disabled, or without a target", () => {
    expect(targetZoneCoachActive({ ...base, paused: true })).toBe(false);
    expect(targetZoneCoachActive({ ...base, measuring: false })).toBe(false);
    expect(targetZoneCoachActive({ ...base, enabled: false })).toBe(false);
    expect(targetZoneCoachActive({ ...base, hasTarget: false })).toBe(false);
  });
});
