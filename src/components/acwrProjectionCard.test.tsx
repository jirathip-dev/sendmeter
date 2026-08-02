import { describe, it, expect } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import AcwrProjectionCard, { Chart } from "./AcwrProjectionCard";
import { PHASES } from "../constants";
import { daysAgo } from "../lib/dates";
import { projectAcwr, REST_DAY_ACWR_DECAY } from "../lib/acwrProjection";
import type { Session } from "../types";

/// The projection maths is pinned in `lib/acwrProjection.test.ts`; this covers
/// the promise the card makes. Rendering to static markup is the same trick
/// `workoutChartAlignment.test.tsx` uses.

const CAPACITY = PHASES.find((p) => p.id === "capacity")!;

function session(date: string, load: number): Session {
  return {
    id: `s-${date}`,
    date,
    type: "board",
    typeLabel: "Board",
    duration: 60,
    rpe: load / 60,
    rpeConfirmed: true,
    load,
    note: "",
    phase: "capacity",
    groupId: null,
    workoutSource: null,
  };
}

const history = Array.from({ length: 40 }, (_, i) => session(daysAgo(i), 300));

function render(sessions: Session[]) {
  return renderToStaticMarkup(<AcwrProjectionCard phase={CAPACITY} sessions={sessions} />);
}

function axisLabel(html: string, name: string): Record<string, string> {
  const tag = html.match(new RegExp(`<text[^>]*data-axis-label="${name}"[^>]*>`))?.[0];
  expect(tag).toBeDefined();
  return Object.fromEntries(
    Array.from(tag!.matchAll(/([\w-]+)="([^"]*)"/g), ([, key, value]) => [key, value]),
  );
}

function renderChart(startingAcwr: number) {
  const projection = projectAcwr(
    { acute: startingAcwr * 100, chronic: 100 },
    { low: 0.9, high: 1.1 },
  )!;
  return {
    html: renderToStaticMarkup(<Chart p={projection} todayColor="green" />),
    projection,
  };
}

describe("AcwrProjectionCard", () => {
  it("states the zero-training assumption up front", () => {
    expect(render(history)).toContain("If you train nothing");
  });

  it("names the phase band and the day the curve leaves it", () => {
    const html = render(history);
    expect(html).toContain("Capacity band (0.9–1.1)");
    expect(html).toContain("Drops below your");
  });

  it("prices staying in band as a session, not a bare load number", () => {
    expect(render(history)).toMatch(/min @ RPE \d/);
  });

  it("draws no NaN coordinates", () => {
    expect(render(history)).not.toContain("NaN");
  });

  it("puts a day-1 crossing on a separate axis row from both endpoints", () => {
    const { html, projection } = renderChart(1);
    expect(projection.fallsBelow?.dayOffset).toBe(1);

    const now = axisLabel(html, "now");
    const crossing = axisLabel(html, "crossing");
    const horizon = axisLabel(html, "horizon");
    expect(now.y).toBe(horizon.y);
    expect(crossing.y).not.toBe(now.y);
  });

  it("keeps a day-7 crossing label inside the right edge", () => {
    const daySevenStart = (0.9 / REST_DAY_ACWR_DECAY ** 6) * 1.01;
    const { html, projection } = renderChart(daySevenStart);
    expect(projection.fallsBelow?.dayOffset).toBe(7);

    const crossing = axisLabel(html, "crossing");
    const horizon = axisLabel(html, "horizon");
    expect(Number(crossing.x)).toBeLessThan(Number(horizon.x));
  });

  it("degrades to an explainer with no session history", () => {
    const html = render([]);
    expect(html).toContain("Log a few sessions");
    expect(html).not.toContain("<svg");
    expect(html).not.toContain("Readiness");
  });
});
