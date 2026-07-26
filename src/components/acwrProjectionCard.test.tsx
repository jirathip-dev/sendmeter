import { describe, it, expect } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import AcwrProjectionCard from "./AcwrProjectionCard";
import { PHASES } from "../constants";
import { daysAgo, today } from "../lib/dates";
import type { HealthMetric, Session } from "../types";

/// The projection maths is pinned in `lib/acwrProjection.test.ts`; this covers
/// the promise the CARD makes — above all that today's readiness can never be
/// mistaken for a projected one (issue #224). Rendering to static markup is
/// the same trick `workoutChartAlignment.test.tsx` uses.

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

function metric(date: string, readiness: number | null, zone: string | null): HealthMetric {
  return {
    date,
    readiness,
    zone,
    computedAt: `${date}T12:00:00Z`,
    hrvSdnnMs: 48,
    restingHr: 52,
    sleepHours: 7.4,
    sleepDeepHours: 1.1,
    sleepRemHours: 1.6,
    bodyMassKg: 68,
    respRateBpm: 14,
  };
}

const history = Array.from({ length: 40 }, (_, i) => session(daysAgo(i), 300));

function render(sessions: Session[], readiness: HealthMetric | null) {
  return renderToStaticMarkup(
    <AcwrProjectionCard phase={CAPACITY} sessions={sessions} latestReadiness={readiness} />,
  );
}

describe("AcwrProjectionCard", () => {
  it("states the zero-training assumption up front", () => {
    expect(render(history, null)).toContain("If you train nothing");
  });

  it("names the phase band and the day the curve leaves it", () => {
    const html = render(history, null);
    expect(html).toContain("Capacity band (0.9–1.1)");
    expect(html).toContain("Drops below your");
  });

  it("prices staying in band as a session, not a bare load number", () => {
    expect(render(history, null)).toMatch(/min @ RPE \d/);
  });

  it("draws no NaN coordinates", () => {
    expect(render(history, metric(today(), 71, "push"))).not.toContain("NaN");
  });

  it("labels readiness as measured today — never as part of the projection", () => {
    const html = render(history, metric(today(), 71, "push"));
    expect(html).toContain("Readiness ·");
    expect(html).toContain("today");
    expect(html).toContain("Measured, not projected");
    expect(html).toContain(">71<");
  });

  it("says WHICH day a stale reading is from rather than passing it off as today's", () => {
    const html = render(history, metric(daysAgo(1), 64, "maintain"));
    expect(html).toContain("yesterday");
    expect(html).toContain("Measured, not projected");
  });

  it("shows an em dash, not a projected guess, when there's no reading at all", () => {
    const html = render(history, null);
    expect(html).toContain("no reading");
    expect(html).toContain(">—<"); // the score slot itself, not prose
  });

  it("degrades to an explainer with no session history", () => {
    const html = render([], metric(today(), 71, "push"));
    expect(html).toContain("Log a few sessions");
    expect(html).not.toContain("<svg");
    // The readiness footer is real data and stays either way.
    expect(html).toContain("Measured, not projected");
  });
});
