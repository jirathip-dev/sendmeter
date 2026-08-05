import { describe, expect, it } from "vitest";
import type { TindeqRecordingMeta } from "../types";
import { applyRecordingEdits } from "./recordingEdits";

const recording = (
  overrides: Partial<TindeqRecordingMeta> = {},
): TindeqRecordingMeta => ({
  id: "rec-1",
  recordedAt: "2026-08-01T10:00:00Z",
  durationMs: 10_000,
  peakKg: 40,
  avgKg: 30,
  sampleCount: 10,
  note: "",
  tag: "FDP",
  side: "left",
  groupId: null,
  protocolRunId: null,
  setNo: null,
  zone: null,
  source: "dynamometer",
  ...overrides,
});

describe("applyRecordingEdits", () => {
  it("leaves recordings with no override untouched", () => {
    const rec = recording();
    expect(applyRecordingEdits([rec], new Map())).toEqual([rec]);
  });

  it("merges only tag/side/note from the override onto the fresh row", () => {
    const fresh = recording({ tag: "FDP", side: "left", note: "", groupId: "session-1" });
    const stale = recording({ tag: "3FDP", side: "right", note: "burly", groupId: null });
    const edits = new Map([[fresh.id, stale]]);

    const [merged] = applyRecordingEdits([fresh], edits);

    expect(merged).toEqual({
      ...fresh,
      tag: "3FDP",
      side: "right",
      note: "burly",
    });
    // The fresh row's groupId must win — a stale override must never
    // resurrect a null groupId after the recording was grouped server-side.
    expect(merged?.groupId).toBe("session-1");
  });

  it("does not mutate the input arrays", () => {
    const fresh = recording();
    const recordings = [fresh];
    const edits = new Map([[fresh.id, recording({ tag: "changed" })]]);

    applyRecordingEdits(recordings, edits);

    expect(recordings[0]).toBe(fresh);
  });
});
