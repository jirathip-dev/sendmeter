import { beforeEach, describe, expect, it, vi } from "vitest";
import { today } from "../dates";

/// #615: `insertPhoneWorkout` used to perform three separate,
/// non-transactional requests (`sessions` insert, `climb_workouts` insert,
/// `climb_attempts` insert) and wait for all three before publishing
/// success — a mid-flight failure stranded a session without its workout,
/// and no retry could be idempotent (all ids were DB-minted). The fix moves
/// all three writes into ONE DB transaction via `create_phone_workout` (see
/// supabase/migrations/20260814090000_phone_workout_rpc.sql) and this
/// function now does nothing but call it with the caller's stable ids.
///
/// This test pins that structurally, the same way
/// `tindeq.linkRecordings.test.ts` pins `linkRecordingsToSession`: the old
/// implementation calls `supabase.from(...)` (this fake throws if it's ever
/// touched) instead of `supabase.rpc(...)`, so asserting `from` was never
/// called catches the non-atomic three-request shape directly, and asserting
/// the exact `rpc` call args catches a call that silently drops a parameter
/// (notably the stable ids that make replays idempotent).
const h = vi.hoisted(() => ({
  rpcResult: { data: null as unknown, error: null as unknown },
}));

const rpc = vi.fn(() => ({
  single: vi.fn(() => Promise.resolve(h.rpcResult)),
}));
const from = vi.fn(() => {
  throw new Error(
    "insertPhoneWorkout must not touch supabase.from(...) directly — " +
      "every write belongs inside the create_phone_workout RPC.",
  );
});

vi.mock("../supabase", () => ({
  supabase: { rpc, from },
}));

const { insertPhoneWorkout } = await import("./workouts");

/// The fixture date is pinned to `today()` (the same helper
/// `insertPhoneWorkout` uses for `p_date`), not a literal: a hardcoded date
/// goes stale the day after it is written and the whole suite starts
/// failing on CI's clock (#615 follow-up). Computed once at module scope so
/// the row and the expected RPC args can't disagree with each other.
const FIXTURE_DATE = today();

/// The workout's timestamps share the fixture day (they are passed through
/// verbatim, so they could stay literal — deriving them from the date keeps
/// the fixture one coherent day instead of two).
const FIXTURE_TIMES = {
  start: `${FIXTURE_DATE}T10:00:00.000Z`,
  end: `${FIXTURE_DATE}T10:45:30.000Z`,
  attempt1: `${FIXTURE_DATE}T10:05:00.000Z`,
  attempt2: `${FIXTURE_DATE}T10:20:00.000Z`,
};

const CANONICAL_ROW = {
  id: "session-1",
  date: FIXTURE_DATE,
  type: "gym",
  type_label: "Gym",
  duration_min: 45,
  rpe: 6,
  rpe_confirmed: false,
  load: 270,
  note: "2 boulders",
  phase: "capacity",
  group_id: null,
  workout_source: "phone",
};

describe("insertPhoneWorkout (#615)", () => {
  beforeEach(() => {
    rpc.mockClear();
    from.mockClear();
    h.rpcResult = { data: null, error: null };
  });

  it("saves via exactly one RPC call carrying stable ids + attempts", async () => {
    h.rpcResult = { data: CANONICAL_ROW, error: null };
    const saved = await insertPhoneWorkout({
      sessionId: "session-1",
      workoutId: "workout-1",
      startedAt: FIXTURE_TIMES.start,
      endedAt: FIXTURE_TIMES.end,
      attempts: [
        { startedAt: FIXTURE_TIMES.attempt1, durationS: 90 },
        { startedAt: FIXTURE_TIMES.attempt2, durationS: 75 },
      ],
      type: "gym",
      typeLabel: "Gym",
      rpe: 6,
      phase: "capacity",
    });
    expect(rpc).toHaveBeenCalledTimes(1);
    expect(rpc).toHaveBeenCalledWith("create_phone_workout", {
      p_session_id: "session-1",
      p_workout_id: "workout-1",
      p_date: FIXTURE_DATE,
      p_type: "gym",
      p_type_label: "Gym",
      p_duration_min: 46, // Math.round(45.5) from the 45m30s span, clamped 1..600
      p_rpe: 6,
      p_note: "2 boulders",
      p_phase: "capacity",
      p_started_at: FIXTURE_TIMES.start,
      p_ended_at: FIXTURE_TIMES.end,
      p_attempts: [
        { started_at: FIXTURE_TIMES.attempt1, duration_s: 90 },
        { started_at: FIXTURE_TIMES.attempt2, duration_s: 75 },
      ],
    });
    // The canonical row returned by the RPC is what callers reconcile with.
    expect(saved).toMatchObject({
      id: "session-1",
      duration: 45,
      rpe: 6,
      rpeConfirmed: false,
      load: 270,
      workoutSource: "phone",
    });
  });

  it("throws — does not swallow — when the RPC reports a Postgrest error", async () => {
    h.rpcResult = { data: null, error: { message: "permission denied" } };
    await expect(
      insertPhoneWorkout({
        sessionId: "session-1",
        workoutId: "workout-1",
        startedAt: FIXTURE_TIMES.start,
        endedAt: FIXTURE_TIMES.end,
        attempts: [],
        type: "gym",
        typeLabel: "Gym",
        rpe: 6,
        phase: "capacity",
      }),
    ).rejects.toMatchObject({ message: "permission denied" });
  });
});
