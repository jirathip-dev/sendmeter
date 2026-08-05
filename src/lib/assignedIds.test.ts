import { describe, expect, it } from "vitest";
import type { TindeqRecordingMeta } from "../types";
import { prunePendingAssignedIds } from "./assignedIds";

const recording = (id: string, groupId: string | null): TindeqRecordingMeta => ({
  id,
  recordedAt: "2026-08-01T10:00:00Z",
  durationMs: 10_000,
  peakKg: 40,
  avgKg: 30,
  sampleCount: 10,
  note: "",
  tag: "FDP",
  side: "left",
  groupId,
  protocolRunId: null,
  setNo: null,
  zone: null,
  source: "dynamometer",
});

describe("prunePendingAssignedIds", () => {
  it("drops an id once the fresh row confirms a non-null groupId", () => {
    const result = prunePendingAssignedIds(
      new Set(["a"]),
      [recording("a", "group-1")],
    );
    expect(result.has("a")).toBe(false);
  });

  it("keeps an id whose fresh row still has a null groupId (refetch not landed yet)", () => {
    const result = prunePendingAssignedIds(new Set(["a"]), [recording("a", null)]);
    expect(result.has("a")).toBe(true);
  });

  it("keeps an id with no matching fresh row (not yet visible in this fetch)", () => {
    const result = prunePendingAssignedIds(new Set(["a"]), []);
    expect(result.has("a")).toBe(true);
  });

  it("returns the same set reference when nothing changes", () => {
    const input = new Set(["a"]);
    const result = prunePendingAssignedIds(input, [recording("a", null)]);
    expect(result).toBe(input);
  });

  it("prunes only the confirmed ids, leaving the rest pending", () => {
    const result = prunePendingAssignedIds(
      new Set(["a", "b"]),
      [recording("a", "group-1"), recording("b", null)],
    );
    expect(result.has("a")).toBe(false);
    expect(result.has("b")).toBe(true);
  });
});
