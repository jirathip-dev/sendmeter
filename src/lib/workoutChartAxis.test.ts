import { describe, it, expect } from "vitest";
import {
  WORKOUT_CHART_PAD,
  attemptWindows,
  fmtMinSec,
  secondsSince,
  workoutTimeMaxS,
  workoutXTicks,
} from "./workoutChartAxis";
import type { WorkoutAttempt, WorkoutHrSample } from "../types";

const START = "2026-07-20T10:00:00Z";
const END = "2026-07-20T10:20:00Z";

const att = (
  startedAt: string,
  durationS: number,
  source: WorkoutAttempt["source"] = "auto",
): WorkoutAttempt => ({
  startedAt,
  durationS,
  elevationGainM: 0,
  avgHr: null,
  peakHr: null,
  effortScore: null,
  source,
});

const trace = (tEnd: number): WorkoutHrSample[] =>
  Array.from({ length: tEnd + 1 }, (_, t) => ({ t, hr: 120 }));

describe("secondsSince", () => {
  it("measures forward from the workout start", () => {
    expect(secondsSince(START, "2026-07-20T10:02:30Z")).toBe(150);
  });
});

describe("attemptWindows", () => {
  it("places each attempt on the trace-seconds timeline", () => {
    expect(
      attemptWindows(START, [
        att("2026-07-20T10:00:30Z", 40),
        att("2026-07-20T10:05:00Z", 20, "manual"),
      ]),
    ).toEqual([
      { start: 30, end: 70, manual: false },
      { start: 300, end: 320, manual: true },
    ]);
  });
});

describe("workoutTimeMaxS", () => {
  it("uses the end of the HR trace when it outlasts the attempts", () => {
    expect(
      workoutTimeMaxS({
        startedAt: START,
        endedAt: END,
        attempts: [att("2026-07-20T10:00:30Z", 40)],
        samples: trace(600),
      }),
    ).toBe(600);
  });

  it("stretches to the last attempt when it runs past the trace", () => {
    // Sensor dropped at 5:00 but the last climb ends at 6:00 — the bar must
    // still land inside the plot area, so the domain follows the attempt.
    expect(
      workoutTimeMaxS({
        startedAt: START,
        endedAt: END,
        attempts: [att("2026-07-20T10:05:30Z", 30)],
        samples: trace(300),
      }),
    ).toBe(360);
  });

  it("ignores endedAt while there is data — a workout left running does not squash the trace", () => {
    expect(
      workoutTimeMaxS({
        startedAt: START,
        endedAt: "2026-07-20T14:00:00Z",
        attempts: [],
        samples: trace(600),
      }),
    ).toBe(600);
  });

  it("falls back to the workout duration with neither trace nor attempts", () => {
    expect(
      workoutTimeMaxS({
        startedAt: START,
        endedAt: END,
        attempts: [],
        samples: null,
      }),
    ).toBe(1200);
  });

  it("never returns a zero-width domain", () => {
    expect(
      workoutTimeMaxS({
        startedAt: START,
        endedAt: START,
        attempts: [],
        samples: [],
      }),
    ).toBe(1);
  });
});

describe("workoutXTicks", () => {
  it("is the same three positions for every chart in the stack", () => {
    expect(workoutXTicks(600)).toEqual([0, 300, 600]);
  });
});

describe("WORKOUT_CHART_PAD", () => {
  it("is shared, so stacked charts reserve the same y-label gutter", () => {
    // The left gutter is what decides where the plot area starts; a chart
    // that reserves a different one silently misaligns the whole x axis.
    expect(WORKOUT_CHART_PAD.left).toBe(26);
    expect(WORKOUT_CHART_PAD.right).toBe(6);
  });
});

describe("fmtMinSec", () => {
  it("formats axis labels as m:ss", () => {
    expect(fmtMinSec(0)).toBe("0:00");
    expect(fmtMinSec(65)).toBe("1:05");
    expect(fmtMinSec(600)).toBe("10:00");
  });

  it("rounds the total first, never emitting a 0:60 remainder", () => {
    // The native side rounds total seconds (119.6 → "2:00"); the web was
    // fixed to match so both platforms label the same axis identically
    // (#645 review F15).
    expect(fmtMinSec(119.6)).toBe("2:00");
    expect(fmtMinSec(59.4)).toBe("0:59");
    expect(fmtMinSec(59.6)).toBe("1:00");
  });
});
