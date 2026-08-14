import { describe, it, expect } from "vitest";
import type { LiveForceMessage } from "sendlog-auth-bridge";
import {
  STALE_MS,
  SPARK_WINDOW_MS,
  FORCE_DIRECT_QUIET_MS,
  isFresh,
  emptyLiveForceMirrorState,
  mergeForceBeat,
  reduceForceBeat,
  rejectionForForce,
  admitLiveForceMessage,
  deriveForceSyncState,
  isBeatVisible,
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
        lastAcceptedAtMs: 0,
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
      { beat: null, cursor: { runId: null, sequence: null, terminal: false, updatedAtMs: null }, lastAcceptedAtMs: 0 },
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
      { beat: null, cursor: { runId: null, sequence: null, terminal: false, updatedAtMs: null }, lastAcceptedAtMs: 0 },
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
        lastAcceptedAtMs: 0,
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

describe("rejectionForForce", () => {
  it("classifies an old run, post-terminal, duplicate and out-of-order packets", () => {
    const cursor = {
      runId: "force-run-1",
      sequence: 5,
      terminal: false,
      updatedAtMs: 1_000_000,
    };
    expect(rejectionForForce(cursor, "force-run-2", 1)).toBe("staleRun");
    expect(rejectionForForce({ ...cursor, terminal: true }, "force-run-1", 6)).toBe(
      "afterTerminal",
    );
    expect(rejectionForForce(cursor, "force-run-1", 5)).toBe("duplicate");
    expect(rejectionForForce(cursor, "force-run-1", 4)).toBe("outOfOrder");
    expect(rejectionForForce({ ...cursor, sequence: null }, "force-run-1", null)).toBe(
      "notFresh",
    );
  });
});

describe("admitLiveForceMessage rejection", () => {
  it("names ownerMismatch for a rejected owner", () => {
    const result = admitLiveForceMessage(
      emptyLiveForceMirrorState(),
      msg({ account_user_id: "user-2" }),
      "user-1",
      false,
    );
    expect(result.accepted).toBe(false);
    expect(result.rejection).toBe("ownerMismatch");
  });

  it("names the sequence rejection reason for an accepted-owner packet", () => {
    const first = admitLiveForceMessage(
      emptyLiveForceMirrorState(),
      msg({ sequence: 3, account_user_id: "user-1" }),
      "user-1",
      false,
    );
    expect(first.accepted).toBe(true);
    const dup = admitLiveForceMessage(first.state, msg({ sequence: 3, account_user_id: "user-1" }), "user-1", false);
    expect(dup.accepted).toBe(false);
    expect(dup.rejection).toBe("duplicate");
  });
});

describe("deriveForceSyncState", () => {
  function acceptedState(updatedAtSec: number, nowMs: number) {
    return reduceForceBeat(
      emptyLiveForceMirrorState(),
      msg({ sequence: 1, updated_at: updatedAtSec }),
      nowMs,
    ).state;
  }

  it("unknown when nothing was ever seen or the run ended", () => {
    expect(deriveForceSyncState(emptyLiveForceMirrorState(), Date.now())).toBe("unknown");
    const terminal = reduceForceBeat(
      acceptedState(1_000, 1_000_000),
      msg({ sequence: 2, status: "idle", event: "end", terminal: true, updated_at: 1_001 }),
      1_000_001,
    ).state;
    expect(deriveForceSyncState(terminal, 1_000_002)).toBe("unknown");
  });

  it("watch-direct while the phone keeps accepting beats", () => {
    const s = acceptedState(100, 1_000_000);
    expect(deriveForceSyncState(s, 1_000_000 + 500)).toBe("watch-direct");
  });

  it("temporarily-unreachable once the phone has accepted nothing for the quiet window", () => {
    const s = acceptedState(100, 1_000_000);
    expect(deriveForceSyncState(s, 1_000_000 + FORCE_DIRECT_QUIET_MS + 1)).toBe(
      "temporarily-unreachable",
    );
  });

  it("stale once the phone has accepted nothing past STALE_MS (#614 review F7)", () => {
    const s = acceptedState(100, 1_000_000);
    expect(deriveForceSyncState(s, 1_000_000 + STALE_MS + 1)).toBe("stale");
  });

  it("bases quiet-state on phone-local receipt time, not the watch clock (#614 review F8)", () => {
    // The beat's updatedAt says 100ms ago (fresh by the WATCH clock), but the
    // phone accepted it FORCE_DIRECT_QUIET_MS ago — a watch clock running
    // ahead must not make a silent link read as healthy.
    const s = acceptedState(1_000_000, 1_000_000);
    expect(deriveForceSyncState(s, 1_000_000 + FORCE_DIRECT_QUIET_MS + 1)).toBe(
      "temporarily-unreachable",
    );
  });

  // #614 round-2 N1: the ~2 Hz cadence only exists while measuring. Between
  // reps the watch is `connected` and sends no periodic beats, so long silence
  // there is a normal rest and must stay healthy/non-alarming.
  it("a connected inter-rep rest of 60-180s stays healthy, never alarming", () => {
    const connected = reduceForceBeat(
      emptyLiveForceMirrorState(),
      msg({ sequence: 1, status: "connected", updated_at: 100 }),
      1_000_000,
    ).state;
    for (const silence of [60_000, 120_000, 180_000]) {
      expect(deriveForceSyncState(connected, 1_000_000 + silence)).toBe("watch-direct");
    }
  });

  it("a measuring last beat still warns after mid-hold silence (#614 round-2 N1)", () => {
    // Same silence windows as the connected case — the alarm must NOT have
    // been disabled wholesale, only gated on the measuring status.
    const measuring = reduceForceBeat(
      emptyLiveForceMirrorState(),
      msg({ sequence: 1, status: "measuring", updated_at: 100 }),
      1_000_000,
    ).state;
    expect(deriveForceSyncState(measuring, 1_000_000 + FORCE_DIRECT_QUIET_MS + 1)).toBe(
      "temporarily-unreachable",
    );
    expect(deriveForceSyncState(measuring, 1_000_000 + STALE_MS + 1)).toBe("stale");
  });
});

describe("isBeatVisible (#614 round-2 N3)", () => {
  function beat(overrides: Partial<LiveForce> = {}): LiveForce {
    return {
      runId: "force-run-1",
      sequence: 1,
      event: "telemetry",
      terminal: false,
      status: "measuring",
      kg: 20,
      peakKg: 25,
      elapsedMs: 1000,
      sessionCount: 1,
      tag: "MVC",
      side: "left",
      updatedAt: 1_000_000,
      spark: [],
      ...overrides,
    };
  }

  it("is judged by the phone's receipt clock, not the watch's updatedAt", () => {
    // The beat's own timestamp says it is ancient (watch clock lagging), yet
    // the phone accepted it moments ago — it must render.
    expect(
      isBeatVisible(beat({ updatedAt: 1_000_000 - 60_000 }), 1_000_000, 1_000_000 + 500),
    ).toBe(true);
    // And a watch clock AHEAD must not hide it either.
    expect(
      isBeatVisible(beat({ updatedAt: 1_000_000 + 60_000 }), 1_000_000, 1_000_000 + 500),
    ).toBe(true);
  });

  it("hides once the phone has accepted nothing for STALE_MS", () => {
    expect(isBeatVisible(beat(), 1_000_000, 1_000_000 + STALE_MS)).toBe(true);
    expect(isBeatVisible(beat(), 1_000_000, 1_000_000 + STALE_MS + 1)).toBe(false);
  });

  it("hides a null or terminal beat", () => {
    expect(isBeatVisible(null, 1_000_000, 1_000_000)).toBe(false);
    expect(isBeatVisible(beat({ terminal: true }), 1_000_000, 1_000_000)).toBe(false);
  });
});

describe("#614 round-2 N4 — lastAcceptedAtMs is always the phone clock", () => {
  it("reduceForceBeat writes the nowMs it is given, ignoring the incoming state's seed", () => {
    // A hostile/legacy seed (a watch-clock ms value) must be discarded.
    const seeded = {
      beat: null,
      cursor: { runId: "force-run-1", sequence: 1, terminal: false, updatedAtMs: 5_000 },
      lastAcceptedAtMs: 4_999_999,
    };
    const result = reduceForceBeat(seeded, msg({ sequence: 2 }), 1_234_567);
    expect(result.accepted).toBe(true);
    expect(result.state.lastAcceptedAtMs).toBe(1_234_567);
  });

  it("mergeForceBeat seeds phone-local, never a watch clock", () => {
    // mergeForceBeat returns the beat, not the state, so the observable
    // contract is that a `prev` with an ancient watch-clock timestamp still
    // merges without the seed being able to leak anywhere.
    const prev = {
      runId: "force-run-1",
      sequence: 1,
      event: "telemetry" as const,
      terminal: false,
      status: "connected" as const,
      kg: 10,
      peakKg: 10,
      elapsedMs: 0,
      sessionCount: 1,
      tag: "",
      side: "",
      updatedAt: 123_456, // an entirely different (watch) clock era
      spark: [],
    };
    const merged = mergeForceBeat(prev, msg({ sequence: 2, status: "connected", updated_at: 2_000 }));
    expect(merged?.runId).toBe("force-run-1");
    expect(merged?.updatedAt).toBe(2_000_000);
  });
});
