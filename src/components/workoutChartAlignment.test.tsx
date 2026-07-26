import { describe, it, expect } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import WorkoutEffortChart from "./WorkoutEffortChart";
import WorkoutHrChart from "./WorkoutHrChart";
import { WORKOUT_CHART_PAD, workoutTimeMaxS } from "../lib/workoutChartAxis";
import type { WorkoutAttempt, WorkoutHrSample } from "../types";

/// The pixel-level half of SL-183: the two stacked charts must map the same
/// instant to the same x. Rendering both to static markup and comparing the
/// coordinates is the only way to catch a future divergence (a chart growing
/// its own padding, domain or width) — the helper unit tests only cover the
/// inputs.

const START = "2026-07-20T10:00:00Z";
const W = 340;

const att = (offsetS: number, durationS: number, effortScore: number): WorkoutAttempt => ({
  startedAt: new Date(new Date(START).getTime() + offsetS * 1000).toISOString(),
  durationS,
  elevationGainM: 1.2,
  avgHr: 150,
  peakHr: 170,
  effortScore,
  source: "auto",
});

const attempts = [att(30, 40, 6.5), att(300, 25, 8), att(540, 35, 4.2)];
const samples: WorkoutHrSample[] = Array.from({ length: 601 }, (_, t) => ({
  t,
  hr: 120 + (t % 30),
}));
const tMax = workoutTimeMaxS({
  startedAt: START,
  endedAt: "2026-07-20T10:12:00Z",
  attempts,
  samples,
});

const hrMarkup = renderToStaticMarkup(
  <WorkoutHrChart
    startedAt={START}
    attempts={attempts}
    samples={samples}
    tMax={tMax}
    width={W}
    showTimeAxis
    source="watch"
  />,
);
const effortMarkup = renderToStaticMarkup(
  <WorkoutEffortChart
    startedAt={START}
    attempts={attempts}
    tMax={tMax}
    width={W}
    showTimeAxis
  />,
);

function matchAll(markup: string, re: RegExp): string[] {
  return [...markup.matchAll(re)].map((m) => m[1]!);
}

describe("workout detail chart alignment (SL-183)", () => {
  it("gives both charts the same viewBox width", () => {
    const viewBox = /viewBox="0 0 (\d+) \d+"/;
    expect(hrMarkup.match(viewBox)![1]).toBe(String(W));
    expect(effortMarkup.match(viewBox)![1]).toBe(String(W));
  });

  it("starts and ends both plot areas at the same x", () => {
    // Gridlines span the plot area, so their endpoints are it.
    const grid = /<line x1="([\d.]+)" y1="[\d.]+" x2="([\d.]+)"/g;
    const hrGrid = [...hrMarkup.matchAll(grid)].map((m) => [m[1], m[2]]);
    const effortGrid = [...effortMarkup.matchAll(grid)].map((m) => [m[1], m[2]]);
    expect(hrGrid.length).toBeGreaterThan(0);
    expect(effortGrid.length).toBeGreaterThan(0);
    for (const [x1, x2] of [...hrGrid, ...effortGrid]) {
      expect(x1).toBe(String(WORKOUT_CHART_PAD.left));
      expect(x2).toBe(String(W - WORKOUT_CHART_PAD.right));
    }
  });

  it("puts each attempt at the same x in both charts", () => {
    // HR chart: the shaded climb windows. Effort chart: the bars.
    const shaded = matchAll(hrMarkup, /<rect x="([\d.]+)"[^>]*opacity="0\.12"/g);
    const bars = matchAll(effortMarkup, /<rect x="([\d.]+)"[^>]*rx="1\.5"/g);
    expect(shaded).toHaveLength(attempts.length);
    expect(bars).toEqual(shaded);
  });

  it("places the time-axis ticks at identical x", () => {
    // m:ss labels only — the y-axis labels carry no colon.
    const tick = /<text x="([\d.]+)"[^>]*>\d+:\d\d<\/text>/g;
    const hrTicks = matchAll(hrMarkup, tick);
    const effortTicks = matchAll(effortMarkup, tick);
    expect(hrTicks).toHaveLength(3);
    expect(effortTicks).toEqual(hrTicks);
  });
});
