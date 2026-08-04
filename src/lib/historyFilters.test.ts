import { describe, expect, it } from "vitest";
import type { Session, TindeqRecordingMeta } from "../types";
import {
  historyFilterOptions,
  liveWorkoutMatchesHistoryFilters,
  looseRecordingMatchesHistoryFilters,
  sessionMatchesHistoryFilters,
} from "./historyFilters";

const session = (type: string, groupId: string | null = null): Session => ({
  id: `${type}-${groupId ?? "none"}`,
  date: "2026-08-01",
  type,
  typeLabel: type === "tindeq" ? "Tindeq" : "Climbing",
  duration: 30,
  rpe: 5,
  rpeConfirmed: true,
  load: 150,
  note: "",
  phase: "strength",
  groupId,
  workoutSource: null,
});

const recording = (tag: string, groupId: string | null = null): TindeqRecordingMeta => ({
  id: `${tag || "empty"}-${groupId ?? "loose"}`,
  recordedAt: "2026-08-01T10:00:00Z",
  durationMs: 10_000,
  peakKg: 40,
  avgKg: 30,
  sampleCount: 10,
  note: "",
  tag,
  side: "left",
  groupId,
  protocolRunId: null,
  setNo: null,
  zone: null,
  source: "dynamometer",
});

describe("history filters", () => {
  it("treats loose recordings as Tindeq for the type filter", () => {
    const rec = recording("Crimp");
    expect(looseRecordingMatchesHistoryFilters(rec, "tindeq", null)).toBe(true);
    expect(looseRecordingMatchesHistoryFilters(rec, "climbing", null)).toBe(false);
  });

  it("filters the pinned live workout as its eventual Auto-tracked session", () => {
    expect(liveWorkoutMatchesHistoryFilters(null, null)).toBe(true);
    expect(liveWorkoutMatchesHistoryFilters("auto", null)).toBe(true);
    expect(liveWorkoutMatchesHistoryFilters("tindeq", null)).toBe(false);
    expect(liveWorkoutMatchesHistoryFilters(null, "Crimp")).toBe(false);
  });

  it("matches a grouped Tindeq session when any recording has the tag", () => {
    const grouped = new Map([["group", [recording("Crimp", "group"), recording("Pinch", "group")]]]);
    expect(sessionMatchesHistoryFilters(session("tindeq", "group"), grouped, null, "Pinch")).toBe(true);
    expect(sessionMatchesHistoryFilters(session("climbing"), grouped, null, "Pinch")).toBe(false);
  });

  it("uses AND semantics across type and tag", () => {
    const grouped = new Map([["group", [recording("Crimp", "group")]]]);
    expect(sessionMatchesHistoryFilters(session("tindeq", "group"), grouped, "tindeq", "Crimp")).toBe(true);
    expect(sessionMatchesHistoryFilters(session("tindeq", "group"), grouped, "climbing", "Crimp")).toBe(false);
    expect(looseRecordingMatchesHistoryFilters(recording("Pinch"), "tindeq", "Crimp")).toBe(false);
  });

  it("does not offer or match an empty force tag", () => {
    const blank = recording("");
    const options = historyFilterOptions([], [blank], new Map(), [], null, "");
    expect(options.tags).toEqual([]);
    expect(options.activeTag).toBeNull();
    expect(looseRecordingMatchesHistoryFilters(blank, null, null)).toBe(true);
  });

  it("keeps options independent and safely resets stale selections", () => {
    const grouped = new Map([["group", [recording("Crimp", "group")]]]);
    const options = historyFilterOptions(
      [session("climbing"), session("tindeq", "group")],
      [recording("Pinch")],
      grouped,
      [],
      "removed-type",
      "removed-tag",
    );
    expect(options.types.map((option) => option.id)).toEqual(["climbing", "tindeq"]);
    expect(options.tags).toEqual(["Crimp", "Pinch"]);
    expect(options.activeType).toBeNull();
    expect(options.activeTag).toBeNull();
  });

  it("matches a gauge session whose type was edited away from tindeq", () => {
    // A gauge session's type is user-editable (EditSessionSheet) — the tag
    // match must key off groupId, not the (possibly re-typed) session type.
    const grouped = new Map([["group", [recording("Edge 20mm", "group")]]]);
    expect(
      sessionMatchesHistoryFilters(session("climbing", "group"), grouped, null, "Edge 20mm"),
    ).toBe(true);
  });

  it("excludes hidden tags from the chip options but leaves their recordings matchable", () => {
    const grouped = new Map([["group", [recording("Hidden Tag", "group")]]]);
    const options = historyFilterOptions(
      [session("tindeq", "group")],
      [recording("Crimp")],
      grouped,
      ["Hidden Tag"],
      null,
      null,
    );
    expect(options.tags).toEqual(["Crimp"]);
    // A hidden tag is unreachable via a chip, but a recording carrying it is
    // still found by direct match (the recordings themselves stay visible).
    expect(
      sessionMatchesHistoryFilters(session("tindeq", "group"), grouped, null, "Hidden Tag"),
    ).toBe(true);
  });
});
