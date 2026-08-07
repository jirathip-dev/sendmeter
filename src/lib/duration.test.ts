import { describe, it, expect } from "vitest";
import { clampDurationMin, computeGroupDurationMin } from "./duration";

describe("clampDurationMin", () => {
  it("floors at 1 minute", () => {
    expect(clampDurationMin(0)).toBe(1);
    expect(clampDurationMin(-5)).toBe(1);
    expect(clampDurationMin(0.2)).toBe(1);
  });

  it("ceils at 600 minutes — the DB's duration_min check constraint", () => {
    expect(clampDurationMin(601)).toBe(600);
    expect(clampDurationMin(100000)).toBe(600);
  });

  it("rounds and passes through an in-range value unchanged", () => {
    expect(clampDurationMin(42.4)).toBe(42);
    expect(clampDurationMin(42.6)).toBe(43);
    expect(clampDurationMin(600)).toBe(600);
    expect(clampDurationMin(1)).toBe(1);
  });
});

describe("computeGroupDurationMin", () => {
  it("returns null for an empty group — nothing to compute", () => {
    expect(computeGroupDurationMin([])).toBeNull();
  });

  it("spans first recording's start to last recording's end", () => {
    const recs = [
      { recordedAt: "2026-08-06T10:00:00.000Z", durationMs: 20_000 }, // ends 10:00:20
      { recordedAt: "2026-08-06T10:05:00.000Z", durationMs: 20_000 }, // ends 10:05:20
    ];
    // span = 10:05:20 - 10:00:00 = 5m20s -> rounds to 5min
    expect(computeGroupDurationMin(recs)).toBe(5);
  });

  // #487 (F3): recalcTindeqSessionDuration used to write this straight to
  // duration_min with only a floor of 1, no ceiling — the DB's `between 1
  // and 600` check then rejected the write, but only AFTER the recordings
  // had already been re-grouped onto the session by the caller
  // (linkRecordingsToSession), leaving the user with regrouped recordings
  // and no session at all.
  it("clamps a multi-day span down to the DB's 600-minute ceiling instead of leaving it unclampable", () => {
    const recs = [
      { recordedAt: "2026-07-01T10:00:00.000Z", durationMs: 20_000 },
      { recordedAt: "2026-08-06T10:00:00.000Z", durationMs: 20_000 }, // 36 days later
    ];
    expect(computeGroupDurationMin(recs)).toBe(600);
  });

  it("floors a near-instant span (single very short recording) at 1 minute", () => {
    const recs = [{ recordedAt: "2026-08-06T10:00:00.000Z", durationMs: 500 }];
    expect(computeGroupDurationMin(recs)).toBe(1);
  });
});
