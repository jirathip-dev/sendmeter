import { describe, it, expect } from "vitest";
import { computeTindeqWeeks, selectedTagDays } from "./tindeqConsistency";
import { daysAgo } from "./dates";
import type { TindeqRecordingMeta } from "../types";

function rec(
  recordedAt: string,
  tag: string,
  id = `${recordedAt}-${tag}-${Math.random()}`,
): TindeqRecordingMeta {
  return {
    id,
    recordedAt,
    durationMs: 5000,
    peakKg: 30,
    avgKg: 24,
    sampleCount: 50,
    note: "",
    tag,
    side: "",
    groupId: null,
    zone: null,
    protocolRunId: null,
    setNo: null,
    source: "dynamometer",
  };
}

// ISO instant for a given local day, at 23:30 local time — round-trips
// through dateStr(new Date(iso)) to the same local day regardless of the
// runner's timezone (no DST boundary crossed by 30 minutes).
function isoAt2330Local(daysBack: number): string {
  const d = new Date();
  d.setDate(d.getDate() - daysBack);
  d.setHours(23, 30, 0, 0);
  return d.toISOString();
}

// ISO instant for a given local day, at noon local time — same round-trip
// safety as isoAt2330Local, for fixtures that don't care about the
// late-night edge case. Unlike `${daysAgo(n)}T12:00:00Z` (a fixed UTC
// instant), this stays on the intended local day at any UTC offset,
// including UTC+12:01 and beyond (Chatham, Tonga, Kiritimati).
function isoAtNoonLocal(daysBack: number): string {
  const d = new Date();
  d.setDate(d.getDate() - daysBack);
  d.setHours(12, 0, 0, 0);
  return d.toISOString();
}

describe("computeTindeqWeeks", () => {
  it("empty input yields 8 zero weeks and no tags", () => {
    const { weeks, tags } = computeTindeqWeeks([], []);
    expect(weeks).toHaveLength(8);
    expect(weeks.map((w) => w.label)).toEqual([
      "7w",
      "6w",
      "5w",
      "4w",
      "3w",
      "2w",
      "1w",
      "Now",
    ]);
    expect(weeks.every((w) => w.days === 0)).toBe(true);
    expect(weeks.every((w) => Object.keys(w.byTag).length === 0)).toBe(true);
    expect(tags).toEqual([]);
  });

  it("three recordings on one day, one tag count as a single trained day", () => {
    const today = daysAgo(0);
    const { weeks } = computeTindeqWeeks(
      [rec(`${today}T09:00:00Z`, "FDP"), rec(`${today}T09:05:00Z`, "FDP"), rec(`${today}T09:10:00Z`, "FDP")],
      [],
    );
    const now = weeks.find((w) => w.label === "Now")!;
    expect(now.days).toBe(1);
    expect(now.byTag).toEqual({ FDP: 1 });
  });

  it("two tags on the same day count as one trained day, one per tag", () => {
    const today = daysAgo(0);
    const { weeks, tags } = computeTindeqWeeks(
      [rec(`${today}T09:00:00Z`, "FDP"), rec(`${today}T10:00:00Z`, "Pinch")],
      [],
    );
    const now = weeks.find((w) => w.label === "Now")!;
    expect(now.days).toBe(1);
    expect(now.byTag).toEqual({ FDP: 1, Pinch: 1 });
    expect(tags).toEqual(["FDP", "Pinch"]);
  });

  it("daysAgo(6) lands in Now, daysAgo(7) lands in 1w", () => {
    const { weeks } = computeTindeqWeeks(
      [rec(isoAtNoonLocal(6), "FDP"), rec(isoAtNoonLocal(7), "FDP")],
      [],
    );
    expect(weeks.find((w) => w.label === "Now")!.days).toBe(1);
    expect(weeks.find((w) => w.label === "1w")!.days).toBe(1);
    expect(weeks.find((w) => w.label === "2w")!.days).toBe(0);
  });

  it("excludes recordings older than the 8-week window", () => {
    const { weeks } = computeTindeqWeeks([rec(`${daysAgo(60)}T12:00:00Z`, "FDP")], []);
    expect(weeks.every((w) => w.days === 0)).toBe(true);
  });

  it("buckets an ISO timestamp by its LOCAL day even late at night", () => {
    const { weeks } = computeTindeqWeeks([rec(isoAt2330Local(0), "FDP")], []);
    expect(weeks.find((w) => w.label === "Now")!.days).toBe(1);
  });

  it("a tag trained only outside the 8-week window produces no chip", () => {
    const { tags } = computeTindeqWeeks(
      [rec(`${daysAgo(60)}T12:00:00Z`, "Old"), rec(`${daysAgo(0)}T12:00:00Z`, "FDP")],
      [],
    );
    expect(tags).toEqual(["FDP"]);
  });

  it("hidden tags disappear from days, byTag, and the tag list", () => {
    const today = daysAgo(0);
    const { weeks, tags } = computeTindeqWeeks(
      [rec(`${today}T09:00:00Z`, "FDP"), rec(`${today}T10:00:00Z`, "Hidden")],
      ["Hidden"],
    );
    const now = weeks.find((w) => w.label === "Now")!;
    expect(now.days).toBe(1);
    expect(now.byTag).toEqual({ FDP: 1 });
    expect(tags).toEqual(["FDP"]);
  });
});

describe("selectedTagDays", () => {
  it("returns the week's all-tags total with no tag filter", () => {
    const week = { label: "Now", days: 3, byTag: { FDP: 1, Pinch: 2 } };
    expect(selectedTagDays(week, null)).toBe(3);
  });

  it("returns the tag-filtered count under a filter, not the all-tags total", () => {
    const week = { label: "Now", days: 3, byTag: { FDP: 1, Pinch: 2 } };
    expect(selectedTagDays(week, "FDP")).toBe(1);
  });

  it("returns 0 for a tag with no recordings that week, not the all-tags total", () => {
    const week = { label: "Now", days: 3, byTag: { Pinch: 2 } };
    expect(selectedTagDays(week, "FDP")).toBe(0);
  });
});
