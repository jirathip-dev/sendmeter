import { describe, it, expect } from "vitest";
import type { Session } from "../types";
import {
  dropPendingForAccount,
  mergeFetchedSessions,
  pendingSessionFromPhoneWorkout,
  pendingSessionFromWatchMessage,
  reconcilePendingSession,
  rollbackPendingSession,
  upsertPendingSession,
  workoutDurationMin,
  type PendingWorkout,
} from "./pendingWorkouts";

const ACCOUNT = "user-a";

function canonical(id: string, date = "2026-08-14"): Session {
  return {
    id,
    date,
    type: "gym",
    typeLabel: "Gym",
    duration: 45,
    rpe: 6,
    rpeConfirmed: false,
    load: 270,
    note: "3 boulders",
    phase: "capacity",
    groupId: null,
    workoutSource: "phone",
  };
}

function pending(id: string, date = "2026-08-14"): PendingWorkout {
  return { ...canonical(id, date), pending: true, accountUserId: ACCOUNT };
}

describe("mergeFetchedSessions", () => {
  it("keeps pending rows that the server does not have yet", () => {
    const fetched = [canonical("a")];
    const list = [pending("b", "2026-08-13"), pending("a")];
    const merged = mergeFetchedSessions(list, fetched, ACCOUNT);
    expect(merged.map((s) => s.id).sort()).toEqual(["a", "b"]);
    // The server row wins for a — pending marker gone.
    expect(merged.find((s) => s.id === "a")).toEqual(canonical("a"));
    expect(merged.find((s) => s.id === "b")?.pending).toBe(true);
  });

  it("drops a pending row whose server row arrived (realtime-before-reconcile)", () => {
    const fetched = [canonical("b")];
    const merged = mergeFetchedSessions([pending("b")], fetched, ACCOUNT);
    expect(merged.map((s) => s.id)).toEqual(["b"]);
    expect(merged.find((s) => s.id === "b")?.pending).toBeUndefined();
  });

  it("drops pending rows stamped for a different account (account change mid-flight)", () => {
    const fetched: Session[] = [];
    const merged = mergeFetchedSessions(
      [pending("a"), { ...pending("b"), accountUserId: "user-b" }],
      fetched,
      ACCOUNT,
    );
    expect(merged.map((s) => s.id)).toEqual(["a"]);
  });

  it("sorts by date descending", () => {
    const merged = mergeFetchedSessions(
      [pending("older", "2026-08-13")],
      [canonical("newer", "2026-08-15")],
      ACCOUNT,
    );
    expect(merged.map((s) => s.id)).toEqual(["newer", "older"]);
  });
});

describe("upsertPendingSession (exactly-once under notification replay)", () => {
  it("appends once", () => {
    const once = upsertPendingSession([], pending("s"));
    const twice = upsertPendingSession(once, pending("s"));
    expect(twice.filter((s) => s.id === "s")).toHaveLength(1);
  });

  it("replaces by id when already present (canonical or pending)", () => {
    const replaced = upsertPendingSession([canonical("s")], pending("s"));
    expect(replaced.find((s) => s.id === "s")?.pending).toBe(true);
  });
});

describe("reconcilePendingSession / rollbackPendingSession", () => {
  it("reconcile replaces the pending row by id with the canonical row", () => {
    const saved = canonical("s");
    const reconciled = reconcilePendingSession([pending("s"), pending("t")], saved);
    expect(reconciled.find((s) => s.id === "s")).toEqual(saved);
    expect(reconciled.find((s) => s.id === "t")?.pending).toBe(true);
  });

  it("reconcile appends when the pending row already left the list (refetch merged it)", () => {
    const reconciled = reconcilePendingSession([], canonical("s"));
    expect(reconciled.map((s) => s.id)).toEqual(["s"]);
  });

  it("rollback removes only a still-pending row, never a reconciled one", () => {
    expect(rollbackPendingSession([pending("s")], "s")).toEqual([]);
    expect(rollbackPendingSession([canonical("s")], "s").map((s) => s.id)).toEqual(["s"]);
  });
});

describe("dropPendingForAccount", () => {
  it("keeps canonical rows and same-account pending rows", () => {
    const out = dropPendingForAccount(
      [canonical("a"), pending("b"), { ...pending("c"), accountUserId: "user-b" }],
      ACCOUNT,
    );
    expect(out.map((s) => s.id).sort()).toEqual(["a", "b"]);
  });
});

describe("pendingSessionFromPhoneWorkout", () => {
  it("builds the same row the RPC will commit", () => {
    const p = pendingSessionFromPhoneWorkout({
      sessionId: "s",
      startedAt: "2026-08-14T10:00:00.000Z",
      endedAt: "2026-08-14T10:46:30.000Z",
      attempts: [{ startedAt: "2026-08-14T10:05:00.000Z", durationS: 90 }],
      type: "gym",
      typeLabel: "Gym",
      rpe: 6,
      phase: "capacity",
      accountUserId: ACCOUNT,
    });
    expect(p).toMatchObject({
      id: "s",
      duration: 47, // rounded minutes, same clamp as insertPhoneWorkout
      rpe: 6,
      rpeConfirmed: false, // #114: unreviewed until edited
      note: "1 boulder",
      phase: "capacity",
      workoutSource: "phone",
      pending: true,
      accountUserId: ACCOUNT,
    });
    expect(p.load).toBe(47 * 6);
  });
});

describe("pendingSessionFromWatchMessage", () => {
  it("builds a watch pending row from the compact notification", () => {
    const p = pendingSessionFromWatchMessage(
      {
        session_id: "w-session",
        workout_id: "w-workout",
        started_at: 1_752_000_000,
        ended_at: 1_752_002_100,
        attempt_count: 4,
        duration_min: 35,
        rpe: 6.5,
        phase: "strength",
        type: "auto",
        type_label: "Auto-tracked",
        note: "4 boulders · avg HR 148",
        rpe_confirmed: false,
      },
      ACCOUNT,
    );
    expect(p).toMatchObject({
      id: "w-session",
      duration: 35,
      rpe: 6.5,
      rpeConfirmed: false,
      phase: "strength",
      workoutSource: "watch",
      pending: true,
      accountUserId: ACCOUNT,
      typeLabel: "Auto-tracked",
    });
    expect(p!.date).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });

  it("defaults rpeConfirmed to true when absent (matches the watch's SessionInsert default)", () => {
    const p = pendingSessionFromWatchMessage(
      {
        session_id: "w-session",
        started_at: 1_752_000_000,
        duration_min: 35,
        rpe: 6.5,
      },
      ACCOUNT,
    );
    expect(p).not.toBeNull();
    expect(p!.rpeConfirmed).toBe(true);
  });

  it("returns null on a payload missing required fields (schema drift)", () => {
    expect(pendingSessionFromWatchMessage({ session_id: "s" }, ACCOUNT)).toBeNull();
    expect(pendingSessionFromWatchMessage({}, ACCOUNT)).toBeNull();
  });
});

describe("workoutDurationMin", () => {
  it("clamps to the sessions.duration_min check constraint like the RPC path", () => {
    expect(workoutDurationMin("2026-08-14T10:00:00.000Z", "2026-08-14T10:00:30.000Z")).toBe(1);
    expect(workoutDurationMin("2026-08-14T10:00:00.000Z", "2026-08-15T10:00:00.000Z")).toBe(600);
  });
});
