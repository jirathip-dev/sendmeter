import { describe, it, expect } from "vitest";
import { hrRecoveryBpm, meanEffort, workRestRatio } from "./workoutStats";
import type { WorkoutAttempt, WorkoutHrSample } from "../types";

const att = (
  startedAt: string,
  durationS: number,
  effortScore: number | null = null,
): WorkoutAttempt => ({
  startedAt,
  durationS,
  elevationGainM: 0,
  avgHr: null,
  peakHr: null,
  effortScore,
  source: "manual",
});

describe("meanEffort (SL-99)", () => {
  it("averages the non-null effort scores", () => {
    expect(
      meanEffort([att("t", 10, 40), att("t", 10, 60), att("t", 10, null)]),
    ).toBeCloseTo(50, 5);
  });
  it("is null when no attempt has an effort score", () => {
    expect(meanEffort([att("t", 10), att("t", 10)])).toBeNull();
    expect(meanEffort([])).toBeNull();
  });
});

describe("workRestRatio (SL-99)", () => {
  it("is total climb time over total rest time", () => {
    // climbs 30 + 60 + 30 = 120s; rests 120 + 180 = 300s → 0.4
    const r = workRestRatio([
      att("2026-07-20T10:00:00Z", 30), // ends 10:00:30
      att("2026-07-20T10:02:30Z", 60), // gap 120s, ends 10:03:30
      att("2026-07-20T10:06:30Z", 30), // gap 180s
    ]);
    expect(r).toBeCloseTo(120 / 300, 5);
  });
  it("skips overlapping (non-positive) gaps and needs measurable rest", () => {
    // Two back-to-back attempts with no gap → no rest → null
    expect(
      workRestRatio([att("2026-07-20T10:00:00Z", 30), att("2026-07-20T10:00:30Z", 30)]),
    ).toBeNull();
  });
  it("needs at least two attempts", () => {
    expect(workRestRatio([att("t", 30)])).toBeNull();
    expect(workRestRatio([])).toBeNull();
  });
});

describe("hrRecoveryBpm (SL-85)", () => {
  it("averages HR-at-end minus the low within the window", () => {
    // Attempt ends at t=30 with HR 160; HR falls to 120 by t=80.
    const trace: WorkoutHrSample[] = [];
    for (let t = 0; t <= 120; t += 5) {
      const hr = t <= 30 ? 160 : Math.max(120, 160 - (t - 30));
      trace.push({ t, hr });
    }
    const drop = hrRecoveryBpm(trace, "2026-07-20T10:00:00Z", [
      att("2026-07-20T10:00:00Z", 30),
    ]);
    expect(drop).toBeCloseTo(40, 0); // 160 → 120
  });

  it("returns null with no usable HR", () => {
    expect(
      hrRecoveryBpm([], "2026-07-20T10:00:00Z", [att("2026-07-20T10:00:00Z", 30)]),
    ).toBeNull();
  });
});
