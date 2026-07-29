import { describe, it, expect } from "vitest";
import type { LiveForceMessage } from "sendlog-auth-bridge";
import { STALE_MS, SPARK_WINDOW_MS, isFresh, mergeForceBeat, type LiveForce } from "./liveForceMirror";

function msg(overrides: Partial<LiveForceMessage> = {}): LiveForceMessage {
  return {
    status: "measuring",
    kg: 20,
    peak_kg: 25,
    elapsed_ms: 1000,
    session_count: 1,
    tag: "MVC",
    side: "left",
    updated_at: 1_000, // seconds
    spark: [],
    ...overrides,
  };
}

describe("mergeForceBeat", () => {
  it("returns null on an idle beat", () => {
    expect(mergeForceBeat(null, msg({ status: "idle" }))).toBeNull();
  });

  it("returns null on an idle beat regardless of the previous beat", () => {
    const prev: LiveForce = {
      status: "measuring",
      kg: 10,
      peakKg: 10,
      elapsedMs: 0,
      sessionCount: 1,
      tag: "MVC",
      side: "left",
      updatedAt: 500_000,
      spark: [],
    };
    expect(mergeForceBeat(prev, msg({ status: "idle" }))).toBeNull();
  });

  it("re-anchors relative [t, kg] points to wall-clock time", () => {
    const beat = mergeForceBeat(
      null,
      msg({ updated_at: 100, elapsed_ms: 2000, spark: [[1000, 15], [2000, 18]] }),
    );
    // originMs = updatedAtMs - elapsedMs = 100_000 - 2000 = 98_000
    expect(beat?.spark).toEqual([
      { atMs: 99_000, kg: 15 },
      { atMs: 100_000, kg: 18 },
    ]);
  });

  it("dedups an overlapping resent window, the later beat's kg winning", () => {
    const first = mergeForceBeat(
      null,
      msg({ updated_at: 100, elapsed_ms: 2000, spark: [[1000, 15], [2000, 18]] }),
    );
    // Second beat resends t=2000 (now stale-relative) with a different kg,
    // plus one new point.
    const second = mergeForceBeat(
      first,
      msg({ updated_at: 101, elapsed_ms: 3000, spark: [[1000, 99], [2000, 20]] }),
    );
    // originMs = 101_000 - 3000 = 98_000; resent point at atMs 99_000 (kg 99
    // overwrites 15), new point at atMs 100_000 (kg 20 overwrites 18).
    expect(second?.spark).toEqual([
      { atMs: 99_000, kg: 99 },
      { atMs: 100_000, kg: 20 },
    ]);
  });

  it("trims points older than updatedAt - SPARK_WINDOW_MS", () => {
    const first = mergeForceBeat(
      null,
      msg({ updated_at: 0, elapsed_ms: 0, spark: [[0, 10]] }),
    );
    // First beat: originMs=0, point at atMs 0.
    const second = mergeForceBeat(
      first,
      msg({
        updated_at: (SPARK_WINDOW_MS + 5000) / 1000,
        elapsed_ms: 0,
        spark: [],
      }),
    );
    // cutoff = updatedAtMs - SPARK_WINDOW_MS = 5000, so the atMs=0 point is trimmed.
    expect(second?.spark).toEqual([]);
  });

  it("keeps a point exactly at the trim cutoff", () => {
    const first = mergeForceBeat(
      null,
      msg({ updated_at: 0, elapsed_ms: 0, spark: [[0, 10]] }),
    );
    const second = mergeForceBeat(
      first,
      msg({ updated_at: SPARK_WINDOW_MS / 1000, elapsed_ms: 0, spark: [] }),
    );
    expect(second?.spark).toEqual([{ atMs: 0, kg: 10 }]);
  });

  it("sorts the merged buffer ascending by time", () => {
    const beat = mergeForceBeat(
      null,
      msg({ updated_at: 100, elapsed_ms: 3000, spark: [[3000, 30], [1000, 10], [2000, 20]] }),
    );
    expect(beat?.spark.map((p) => p.kg)).toEqual([10, 20, 30]);
  });

  it("keeps the prior buffer (trimmed) when the beat carries no spark field", () => {
    const first = mergeForceBeat(
      null,
      msg({ updated_at: 10, elapsed_ms: 0, spark: [[0, 10]] }),
    );
    const withoutSpark = msg({ updated_at: 11, elapsed_ms: 0, spark: undefined });
    const second = mergeForceBeat(first, withoutSpark);
    expect(second?.spark).toEqual([{ atMs: 10_000, kg: 10 }]);
  });

  it("fills missing scalar fields with defaults", () => {
    const beat = mergeForceBeat(null, {
      status: "measuring",
      updated_at: 10,
      spark: [],
    });
    expect(beat).toMatchObject({ kg: 0, peakKg: 0, sessionCount: 0, tag: "", side: "" });
  });
});

describe("isFresh", () => {
  const beat: LiveForce = {
    status: "measuring",
    kg: 10,
    peakKg: 10,
    elapsedMs: 0,
    sessionCount: 1,
    tag: "MVC",
    side: "left",
    updatedAt: 10_000,
    spark: [],
  };

  it("is fresh within the staleness window", () => {
    expect(isFresh(beat, 10_000 + STALE_MS)).toBe(true);
  });

  it("is stale just past the staleness window", () => {
    expect(isFresh(beat, 10_000 + STALE_MS + 1)).toBe(false);
  });
});
