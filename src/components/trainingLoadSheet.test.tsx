import { describe, expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { daysAgo } from "../lib/dates";
import type { Session, WeeklyLoad } from "../types";
import TrainingLoadSheet from "./TrainingLoadSheet";

function session(type: string, typeLabel: string, load: number): Session {
  return {
    id: `${type}-${load}`,
    date: daysAgo(0),
    type,
    typeLabel,
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

const weeks: WeeklyLoad[] = [
  { label: "3w", total: 100 },
  { label: "2w", total: 200 },
  { label: "1w", total: 300 },
  { label: "Now", total: 400 },
];

describe("TrainingLoadSheet", () => {
  it("renders the moved load views and 28-day AU percentages", () => {
    const html = renderToStaticMarkup(
      <TrainingLoadSheet
        weeklyLoads={weeks}
        sessions={[
          session("board", "Board Climbing", 300),
          session("gym", "Gym Session", 100),
        ]}
        onClose={() => {}}
      />,
    );

    expect(html).toContain("Training Load");
    expect(html).toContain("Weekly load");
    expect(html).toContain("Daily load");
    expect(html).toContain("Activity mix");
    expect(html).toContain("Last 28 days · 400 AU");
    expect(html).toContain("Board Climbing");
    expect(html).toContain("300 AU · 75%");
    expect(html).toContain("100 AU · 25%");
    expect(html).toContain('data-testid="activity-mix-bar"');
    expect(html).toContain('aria-label="Activity mix: Board Climbing 75%, Gym Session 25%"');

    const boardSegment = html.indexOf('data-activity-type="board"');
    const gymSegment = html.indexOf('data-activity-type="gym"');
    expect(boardSegment).toBeGreaterThan(-1);
    expect(gymSegment).toBeGreaterThan(boardSegment);
    expect(html.slice(boardSegment, gymSegment)).toContain("width:75%");
    expect(html.slice(gymSegment)).toContain("width:25%");
  });

  it("fills the mix bar for one positive activity", () => {
    const html = renderToStaticMarkup(
      <TrainingLoadSheet
        weeklyLoads={weeks}
        sessions={[session("routine", "Routine", 80)]}
        onClose={() => {}}
      />,
    );

    expect(html).toContain('aria-label="Activity mix: Routine 100%"');
    expect(html).toContain('data-activity-type="routine"');
    expect(html).toContain("width:100%");
    expect(html).toContain("80 AU · 100%");
  });

  it("keeps very small shares proportional without a minimum width", () => {
    const html = renderToStaticMarkup(
      <TrainingLoadSheet
        weeklyLoads={weeks}
        sessions={[
          session("board", "Board Climbing", 999),
          session("gym", "Gym Session", 1),
        ]}
        onClose={() => {}}
      />,
    );

    const gymSegment = html.indexOf('data-activity-type="gym"');
    expect(html.slice(gymSegment)).toContain("width:0.1%");
    expect(html.slice(gymSegment)).not.toContain("min-width");
  });

  it("renders a useful activity-mix empty state", () => {
    const html = renderToStaticMarkup(
      <TrainingLoadSheet weeklyLoads={weeks} sessions={[]} onClose={() => {}} />,
    );

    expect(html).toContain("No training load in the last 28 days");
    expect(html).not.toContain('data-testid="activity-mix-bar"');
  });
});
