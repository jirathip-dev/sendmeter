import { describe, it, expect } from "vitest";
import type { LiveForceMessage } from "sendlog-auth-bridge";
import {
  STALE_MS,
  SPARK_WINDOW_MS,
  isFresh,
  emptyLiveForceMirrorState,
  mergeForceBeat,
  reduceForceBeat,
  type LiveForce,
} from "./liveForceMirror";

function msg(overrides: Partial<LiveForceMessage> = {}): LiveForceMessage {
  return {
    run_id: "force-run-1",
    sequence: 1,
    event: "telemetry",
    terminal: false,
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

// `acceptsPacketOwner` and the account-transition tracking it depends on now
// live in `liveMirrorOwnership.test.ts` (round-1 review F4: single source of
// truth for both mirrors) — including the full-pipeline late-A-after-B
// coverage for this module's `reduceForceBeat`, with a negative control
// proving the reducer alone would have accepted the same packet (F3).

describe("mergeForceBeat", () => {
  it("returns null on an idle beat", () => {
    expect(mergeForceBeat(null, msg({ status: "idle" }))).toBeNull();
  });

  it("returns null on an idle beat regardless of the previous beat", () => {
    const prev: LiveForce = {
      runId: "force-run-1",
      sequence: 1,
      event: "telemetry",
      terminal: false,
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
      msg({ sequence: 2, updated_at: 101, elapsed_ms: 3000, spark: [[1000, 99], [2000, 20]] }),
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
        sequence: 2,
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
      msg({ sequence: 2, updated_at: SPARK_WINDOW_MS / 1000, elapsed_ms: 0, spark: [] }),
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
    const withoutSpark = msg({ sequence: 2, updated_at: 11, elapsed_ms: 0, spark: undefined });
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
    runId: "force-run-1",
    sequence: 1,
    event: "telemetry",
    terminal: false,
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

describe("reduceForceBeat", () => {
  it("rejects duplicate and out-of-order telemetry", () => {
    const first = mergeForceBeat(null, msg({ sequence: 4, updated_at: 100 }));
    expect(first).not.toBeNull();
    const duplicate = mergeForceBeat(first, msg({ sequence: 4, updated_at: 101, kg: 99 }));
    expect(duplicate).toBe(first);
    const older = mergeForceBeat(first, msg({ sequence: 3, updated_at: 102, kg: 98 }));
    expect(older).toBe(first);
  });

  it("keeps a terminal cursor so a late measuring beat cannot reopen the mirror", () => {
    const first = mergeForceBeat(null, msg({ sequence: 1, updated_at: 100 }));
    const terminal = reduceForceBeat(
      {
        beat: first,
        cursor: { runId: "force-run-1", sequence: 1, terminal: false, updatedAtMs: 100_000 },
      },
      msg({ sequence: 2, status: "idle", event: "end", terminal: true, updated_at: 101 }),
    );
    expect(terminal.accepted).toBe(true);
    expect(terminal.state.beat).toBeNull();
    const late = reduceForceBeat(terminal.state, msg({ sequence: 3, updated_at: 102 }));
    expect(late.accepted).toBe(false);
    expect(late.state).toBe(terminal.state);
  });

  it("rotates a legacy force identity only on a fresh connected transition", () => {
    const initial = reduceForceBeat(
      { beat: null, cursor: { runId: null, sequence: null, terminal: false, updatedAtMs: null } },
      { ...msg({ run_id: undefined, sequence: undefined, status: "connected", updated_at: 100 }) },
    );
    const terminal = reduceForceBeat(initial.state, {
      ...msg({ run_id: undefined, sequence: undefined, status: "idle", updated_at: 101 }),
    });
    const late = reduceForceBeat(terminal.state, {
      ...msg({ run_id: undefined, sequence: undefined, status: "measuring", updated_at: 102 }),
    });
    expect(late.accepted).toBe(false);
    const fresh = reduceForceBeat(terminal.state, {
      ...msg({ run_id: undefined, sequence: undefined, status: "connected", updated_at: 102 }),
    });
    expect(fresh.accepted).toBe(true);
    expect(fresh.state.cursor.runId).not.toBe(terminal.state.cursor.runId);
  });

  it("normalizes UUID casing on the force cursor", () => {
    const first = reduceForceBeat(
      { beat: null, cursor: { runId: null, sequence: null, terminal: false, updatedAtMs: null } },
      msg({ run_id: "ABCDEFAB-ABCD-4ABC-8ABC-ABCDEFABCDEF", sequence: 1 }),
    );
    const next = reduceForceBeat(first.state, msg({
      run_id: "abcdefab-abcd-4abc-8abc-abcdefabcdef",
      sequence: 2,
      updated_at: 1001,
    }));
    expect(next.accepted).toBe(true);
    expect(next.state.cursor.runId).toBe("abcdefab-abcd-4abc-8abc-abcdefabcdef");
  });

  it("starts a fresh spark buffer for a fresh run and rejects an old run packet", () => {
    const first = reduceForceBeat(
      {
        beat: null,
        cursor: { runId: null, sequence: null, terminal: false, updatedAtMs: null },
      },
      msg({ sequence: 8, updated_at: 100, spark: [[0, 10]] }),
    );
    const fresh = reduceForceBeat(first.state, {
      ...msg({ run_id: "force-run-2", sequence: 1, updated_at: 101, spark: [[0, 20]] }),
    });
    expect(fresh.accepted).toBe(true);
    expect(fresh.state.beat?.spark).toEqual([{ atMs: 100_000, kg: 20 }]);
    const old = reduceForceBeat(fresh.state, msg({ run_id: "force-run-1", sequence: 9, updated_at: 99 }));
    expect(old.accepted).toBe(false);
  });

  it("resets the ordering cursor when the authenticated account changes", () => {
    const accountA = reduceForceBeat(
      emptyLiveForceMirrorState(),
      msg({ run_id: "account-a-run", sequence: 99, updated_at: 200 }),
    ).state;
    // B may legitimately have an older wall clock than A; only an account
    // reset can make its first sequence eligible.
    expect(
      reduceForceBeat(
        accountA,
        msg({ run_id: "account-b-run", sequence: 1, updated_at: 100 }),
      ).accepted,
    ).toBe(false);
    const accountB = reduceForceBeat(
      emptyLiveForceMirrorState(),
      msg({ run_id: "account-b-run", sequence: 1, updated_at: 100 }),
    );
    expect(accountB.accepted).toBe(true);
    expect(accountB.state.cursor.runId).toBe("account-b-run");
  });
});
