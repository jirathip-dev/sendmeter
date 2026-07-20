import { describe, it, expect } from "vitest";
import { climbRestStats, hrRecoveryBpm } from "./workoutStats";
import type { WorkoutAttempt, WorkoutHrSample } from "../types";

const att = (startedAt: string, durationS: number): WorkoutAttempt => ({
  startedAt,
  durationS,
  elevationGainM: 0,
  avgHr: null,
  peakHr: null,
  effortScore: null,
  source: "manual",
});

describe("climbRestStats (SL-85)", () => {
  it("averages attempt durations and the gaps between them", () => {
    const { avgClimbS, avgRestS } = climbRestStats([
      att("2026-07-20T10:00:00Z", 30), // ends 10:00:30
      att("2026-07-20T10:02:30Z", 60), // gap 120s, ends 10:03:30
      att("2026-07-20T10:06:30Z", 30), // gap 180s
    ]);
    expect(avgClimbS).toBeCloseTo(40, 5);
    expect(avgRestS).toBeCloseTo(150, 5);
  });

  it("needs two attempts for a rest figure", () => {
    const one = climbRestStats([att("2026-07-20T10:00:00Z", 30)]);
    expect(one.avgClimbS).toBe(30);
    expect(one.avgRestS).toBeNull();
    expect(climbRestStats([]).avgClimbS).toBeNull();
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
