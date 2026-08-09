import { describe, it, expect, vi } from "vitest";

// Importing useTrainingData.ts (to reach its exported pure helpers, mirroring
// useTindeq.test.ts's pattern) also pulls in `../lib/supabase`'s module-level
// `createClient(...)` call. That's unrelated to anything under test here —
// none of these tests touch the real client — but constructing it eagerly
// crashes under Node <22 (no native `WebSocket`, which
// @supabase/realtime-js's RealtimeClient constructor requires; this repo's
// CI pins Node 22 in every workflow for exactly this reason). Mock the
// module so the import graph never constructs a real client; every test
// below only exercises pure functions with injected fakes.
vi.mock("../lib/supabase", () => ({
  supabase: { auth: { refreshSession: vi.fn() } },
}));

import {
  addTindeqSessionAction,
  applyAddSessionOptimistic,
  applyEditSessionOptimistic,
  applyRemoveSessionOptimistic,
  applySetPhaseOptimistic,
  createGenerationGuard,
  reconcileAddSession,
  rollbackAddSession,
  rollbackEditSession,
  rollbackRemoveSession,
  rollbackSetPhase,
  runFetchAttempts,
  sortSessions,
  upsertSessionById,
  withOptimisticUpdate,
  type PhaseSnapshot,
  type RunFetchDeps,
} from "./useTrainingData";
import type { PhasePeriod, Session, SessionPatch } from "../types";
import type { UserSettings } from "../lib/repo/settings";

function makeSession(overrides?: Partial<Session>): Session {
  return {
    id: "s1",
    date: "2026-07-20",
    type: "boulder",
    typeLabel: "Boulder",
    duration: 60,
    rpe: 7,
    rpeConfirmed: true,
    load: 420,
    note: "",
    phase: "capacity",
    groupId: null,
    workoutSource: null,
    ...overrides,
  };
}

const SETTINGS: UserSettings = {
  currentPhase: "strength",
  phaseStartDate: "2026-07-01",
};
const PERIODS: PhasePeriod[] = [
  { id: "p1", phase: "strength", startedOn: "2026-07-01", endedOn: null },
];

describe("createGenerationGuard", () => {
  it("returns increasing generations from sequential start() calls", () => {
    const guard = createGenerationGuard();
    expect(guard.start()).toBe(1);
    expect(guard.start()).toBe(2);
    expect(guard.start()).toBe(3);
  });

  it("isCurrent is true only for the most recently started generation", () => {
    const guard = createGenerationGuard();
    const g1 = guard.start();
    const g2 = guard.start();
    expect(guard.isCurrent(g1)).toBe(false);
    expect(guard.isCurrent(g2)).toBe(true);
  });
});

function baseDeps(overrides?: Partial<RunFetchDeps>): RunFetchDeps {
  const guard = createGenerationGuard();
  const generation = guard.start();
  return {
    fetchAll: vi
      .fn()
      .mockResolvedValue([[makeSession()], SETTINGS, PERIODS] as [
        Session[],
        UserSettings,
        PhasePeriod[],
      ]),
    refreshSession: vi.fn().mockResolvedValue(undefined),
    delay: vi.fn().mockResolvedValue(undefined),
    guard,
    generation,
    onSuccess: vi.fn(),
    onError: vi.fn(),
    ...overrides,
  };
}

describe("runFetchAttempts", () => {
  it("stale-resolution guard: fetchAll is called but onSuccess/onError never fire when the generation goes stale", async () => {
    const deps = baseDeps({
      guard: { isCurrent: vi.fn().mockReturnValue(false) },
    });
    await runFetchAttempts(deps);
    expect(deps.fetchAll).toHaveBeenCalledTimes(1);
    expect(deps.onSuccess).not.toHaveBeenCalled();
    expect(deps.onError).not.toHaveBeenCalled();
  });

  it("succeeds after two failures without actually sleeping", async () => {
    const fetchAll = vi
      .fn()
      .mockRejectedValueOnce(new Error("blip 1"))
      .mockRejectedValueOnce(new Error("blip 2"))
      .mockResolvedValueOnce([[makeSession()], SETTINGS, PERIODS] as [
        Session[],
        UserSettings,
        PhasePeriod[],
      ]);
    const onExhausted = vi.fn();
    const deps = baseDeps({ fetchAll, onExhausted });
    await runFetchAttempts(deps);
    expect(fetchAll).toHaveBeenCalledTimes(3);
    expect(deps.onSuccess).toHaveBeenCalledTimes(1);
    expect(deps.onSuccess).toHaveBeenCalledWith({
      sessions: [makeSession()],
      currentPhase: SETTINGS.currentPhase,
      phaseStartDate: SETTINGS.phaseStartDate,
      phasePeriods: PERIODS,
    });
    expect(deps.onError).not.toHaveBeenCalled();
    expect(onExhausted).not.toHaveBeenCalled();
  });

  it("fails all three attempts and surfaces the final error", async () => {
    const fetchAll = vi.fn().mockRejectedValue(new Error("boom"));
    const onExhausted = vi.fn();
    const deps = baseDeps({ fetchAll, onExhausted });
    await runFetchAttempts(deps);
    expect(fetchAll).toHaveBeenCalledTimes(3);
    expect(deps.onSuccess).not.toHaveBeenCalled();
    expect(deps.onError).toHaveBeenCalledTimes(1);
    expect(deps.onError).toHaveBeenCalledWith("boom");
    expect(onExhausted).toHaveBeenCalledOnce();
    expect(onExhausted).toHaveBeenCalledWith(expect.any(Error), 3);
    expect(deps.refreshSession).toHaveBeenCalledTimes(2);
    expect(deps.delay).toHaveBeenCalledTimes(2);
    // Backoff is 400 * (attempt + 1) — verify the actual millisecond values,
    // not just the call count, so a broken multiplier/offset still fails
    // this test.
    expect(deps.delay).toHaveBeenNthCalledWith(1, 400);
    expect(deps.delay).toHaveBeenNthCalledWith(2, 800);
  });

  it("post-failure guard (checkpoint 2): a stale generation after the first failure stops the retry loop before refreshSession/delay run", async () => {
    // fetchAll always rejects, so the success-path guard check (checkpoint 1)
    // is never reached — this isolates the guard check that sits at the top
    // of the catch block, immediately after the first failed attempt and
    // before refreshSession/delay. Mutating that check to a no-op would let
    // fetchAll/refreshSession/delay keep running across all 3 attempts.
    const fetchAll = vi.fn().mockRejectedValue(new Error("boom"));
    const guard = { isCurrent: vi.fn().mockReturnValue(false) };
    const deps = baseDeps({ fetchAll, guard });
    await runFetchAttempts(deps);
    expect(fetchAll).toHaveBeenCalledTimes(1);
    expect(guard.isCurrent).toHaveBeenCalledTimes(1);
    expect(deps.refreshSession).not.toHaveBeenCalled();
    expect(deps.delay).not.toHaveBeenCalled();
    expect(deps.onSuccess).not.toHaveBeenCalled();
    expect(deps.onError).not.toHaveBeenCalled();
  });

  it("final guard (checkpoint 3): a generation that goes stale only after the last attempt suppresses onError despite all 3 attempts running", async () => {
    // guard.isCurrent is called once per failed attempt (checkpoint 2, at
    // the top of the catch block) plus once more after the loop exits
    // (checkpoint 3, right before onError). Staying "current" for the first
    // 3 calls and going stale only on the 4th isolates checkpoint 3: the
    // retry loop runs to completion exactly as it would on a real error,
    // and only the final onError dispatch is suppressed.
    const fetchAll = vi.fn().mockRejectedValue(new Error("boom"));
    let calls = 0;
    const guard = {
      isCurrent: vi.fn(() => {
        calls += 1;
        return calls <= 3;
      }),
    };
    const deps = baseDeps({ fetchAll, guard });
    await runFetchAttempts(deps);
    expect(fetchAll).toHaveBeenCalledTimes(3);
    expect(deps.refreshSession).toHaveBeenCalledTimes(2);
    expect(deps.delay).toHaveBeenCalledTimes(2);
    expect(guard.isCurrent).toHaveBeenCalledTimes(4);
    expect(deps.onSuccess).not.toHaveBeenCalled();
    expect(deps.onError).not.toHaveBeenCalled();
  });

  it("a non-Error rejection surfaces the generic fallback message", async () => {
    const fetchAll = vi.fn().mockRejectedValue("some string rejection");
    const deps = baseDeps({ fetchAll });
    await runFetchAttempts(deps);
    expect(deps.onError).toHaveBeenCalledWith("Failed to load data");
  });

  it("a rejecting refreshSession does not abort the retry sequence", async () => {
    const fetchAll = vi.fn().mockRejectedValue(new Error("boom"));
    const refreshSession = vi.fn().mockRejectedValue(new Error("refresh failed"));
    const deps = baseDeps({ fetchAll, refreshSession });
    await runFetchAttempts(deps);
    expect(fetchAll).toHaveBeenCalledTimes(3);
    expect(refreshSession).toHaveBeenCalledTimes(2);
    expect(deps.onError).toHaveBeenCalledWith("boom");
  });
});

describe("withOptimisticUpdate", () => {
  it("action resolves: apply runs before action, onSuccess fires, rollback/onError never fire", async () => {
    const calls: string[] = [];
    const apply = vi.fn(() => calls.push("apply"));
    const action = vi.fn(async () => {
      calls.push("action");
      return "result";
    });
    const onSuccess = vi.fn();
    const rollback = vi.fn();
    const onError = vi.fn();

    const result = await withOptimisticUpdate({
      apply,
      action,
      onSuccess,
      rollback,
      onError,
      fallbackMessage: "fallback",
    });

    expect(calls).toEqual(["apply", "action"]);
    expect(onSuccess).toHaveBeenCalledWith("result");
    expect(rollback).not.toHaveBeenCalled();
    expect(onError).not.toHaveBeenCalled();
    expect(result).toBe("result");
  });

  it("action rejects with an Error: rollback runs, onError(e.message) fires, onSuccess never fires", async () => {
    const rollback = vi.fn();
    const onSuccess = vi.fn();
    const onError = vi.fn();
    const onFailure = vi.fn();

    const result = await withOptimisticUpdate({
      apply: vi.fn(),
      action: async () => {
        throw new Error("specific failure");
      },
      onSuccess,
      rollback,
      onError,
      fallbackMessage: "fallback",
      onFailure,
    });

    expect(rollback).toHaveBeenCalledTimes(1);
    expect(onError).toHaveBeenCalledWith("specific failure");
    expect(onSuccess).not.toHaveBeenCalled();
    expect(onFailure).toHaveBeenCalledWith(expect.any(Error));
    expect(result).toBeUndefined();
  });

  it("action rejects with a non-Error: onError fires with the fallback message", async () => {
    const onError = vi.fn();

    await withOptimisticUpdate({
      apply: vi.fn(),
      action: async () => {
        throw "not an error object";
      },
      onSuccess: vi.fn(),
      rollback: vi.fn(),
      onError,
      fallbackMessage: "fallback message",
    });

    expect(onError).toHaveBeenCalledWith("fallback message");
  });
});

describe("applyAddSessionOptimistic / reconcileAddSession / rollbackAddSession", () => {
  it("applyAddSessionOptimistic appends the temp row and sorts", () => {
    const existing = [makeSession({ id: "a", date: "2026-07-18" })];
    const temp = makeSession({ id: "temp-1", date: "2026-07-22" });
    const result = applyAddSessionOptimistic(existing, temp);
    expect(result.map((s) => s.id)).toEqual(["temp-1", "a"]);
  });

  it("reconcileAddSession swaps the temp row for the saved one by id, leaving others untouched", () => {
    const other = makeSession({ id: "a", date: "2026-07-18" });
    const temp = makeSession({ id: "temp-1", date: "2026-07-22" });
    const saved = makeSession({ id: "real-1", date: "2026-07-22" });
    const result = reconcileAddSession([other, temp], "temp-1", saved);
    expect(result.map((s) => s.id).sort()).toEqual(["a", "real-1"]);
    expect(result.find((s) => s.id === "a")).toEqual(other);
  });

  it("rollbackAddSession removes exactly the temp row by id", () => {
    const other = makeSession({ id: "a" });
    const temp = makeSession({ id: "temp-1" });
    const result = rollbackAddSession([other, temp], "temp-1");
    expect(result).toEqual([other]);
  });

  it("upserts a retried client-keyed session without duplicating History", () => {
    const old = makeSession({ id: "stable", note: "before" });
    const saved = makeSession({ id: "stable", note: "after" });
    expect(upsertSessionById([old], saved)).toEqual([saved]);
  });
});

describe("addTindeqSessionAction", () => {
  it("returns true and calls onSuccess with the saved session when the insert resolves", async () => {
    const saved = makeSession({ id: "t1", groupId: "g1" });
    const onSuccess = vi.fn();
    const onError = vi.fn();

    const result = await addTindeqSessionAction({
      action: async () => saved,
      onSuccess,
      onError,
    });

    expect(result).toBe(true);
    expect(onSuccess).toHaveBeenCalledWith(saved);
    expect(onError).not.toHaveBeenCalled();
  });

  it("returns false and reports the error message when the insert rejects", async () => {
    const onSuccess = vi.fn();
    const onError = vi.fn();
    const onFailure = vi.fn();

    const result = await addTindeqSessionAction({
      action: async () => {
        throw new Error("insert failed");
      },
      onSuccess,
      onError,
      onFailure,
    });

    expect(result).toBe(false);
    expect(onError).toHaveBeenCalledWith("insert failed");
    expect(onSuccess).not.toHaveBeenCalled();
    expect(onFailure).toHaveBeenCalledWith(expect.any(Error));
  });

  it("falls back to a generic message for a non-Error rejection", async () => {
    const onError = vi.fn();

    const result = await addTindeqSessionAction({
      action: async () => {
        throw "not an error object";
      },
      onSuccess: vi.fn(),
      onError,
    });

    expect(result).toBe(false);
    expect(onError).toHaveBeenCalledWith("Failed to log session");
  });
});

describe("applyEditSessionOptimistic", () => {
  it("merges the patch, forces rpeConfirmed true, and recomputes load", () => {
    const target = makeSession({
      id: "a",
      rpeConfirmed: false,
      duration: 30,
      rpe: 5,
      load: 150,
    });
    const other = makeSession({ id: "b", rpeConfirmed: false });
    const patch: SessionPatch = {
      type: "endurance",
      typeLabel: "Endurance",
      duration: 45,
      rpe: 8,
      note: "felt strong",
    };
    const result = applyEditSessionOptimistic([target, other], "a", patch);
    const edited = result.find((s) => s.id === "a")!;
    expect(edited.type).toBe("endurance");
    expect(edited.typeLabel).toBe("Endurance");
    expect(edited.duration).toBe(45);
    expect(edited.rpe).toBe(8);
    expect(edited.note).toBe("felt strong");
    expect(edited.rpeConfirmed).toBe(true);
    expect(edited.load).toBe(45 * 8);
    const untouched = result.find((s) => s.id === "b")!;
    expect(untouched).toEqual(other);
  });
});

describe("applyRemoveSessionOptimistic", () => {
  it("removes exactly the row with the given id, leaving others untouched and in order", () => {
    const a = makeSession({ id: "a", date: "2026-07-18" });
    const b = makeSession({ id: "b", date: "2026-07-19" });
    const c = makeSession({ id: "c", date: "2026-07-20" });
    const result = applyRemoveSessionOptimistic([a, b, c], "b");
    expect(result).toEqual([a, c]);
  });

  it("is a no-op when the id isn't present", () => {
    const a = makeSession({ id: "a" });
    const b = makeSession({ id: "b" });
    const result = applyRemoveSessionOptimistic([a, b], "missing");
    expect(result).toEqual([a, b]);
  });
});

// #485 F4 — the auditor flagged this but explicitly did NOT prove it
// ("needing a React renderer the repo has no harness for"). Verified for
// real here: `editSession`/`removeSession` used to capture `prev = sessions`
// once, up front, and roll back with a bare `setSessions(prev)` — the whole
// list AS IT STOOD BEFORE THIS OPERATION's own optimistic apply. That
// snapshot is a value from the render this call started in; it has no way
// to see a DIFFERENT mutation (another edit/delete succeeding, or a
// realtime refetch) that lands in the async window between the snapshot and
// this rollback running. `rollback: () => setSessions(prev)` would silently
// revert that other, successful mutation too — exactly CLAUDE.md's #295/#296
// defect class (a decision from state captured earlier than the decision).
//
// `rollbackEditSession`/`rollbackRemoveSession` fix it by taking only the
// ONE row this operation needs to undo, applied via a functional update
// against whatever `sessions` CURRENTLY is at rollback time — never a
// captured whole-list value.
describe("rollbackEditSession / rollbackRemoveSession (#485 F4)", () => {
  it("rollbackEditSession restores only the edited row", () => {
    const original = makeSession({ id: "a", note: "before" });
    const edited = makeSession({ id: "a", note: "after" });
    const other = makeSession({ id: "b" });
    const result = rollbackEditSession([edited, other], "a", original);
    expect(result).toEqual([original, other]);
  });

  it("rollbackEditSession — PROVED. preserves a concurrent mutation to another row, unlike a whole-list snapshot restore", () => {
    const original = makeSession({ id: "a", note: "before" });
    const edited = makeSession({ id: "a", note: "after" });
    // The list as it stands AT ROLLBACK TIME: b has since been deleted by a
    // concurrent, already-succeeded removeSession — the exact interleaving
    // F4 describes.
    const currentList = [edited]; // b is gone
    const result = rollbackEditSession(currentList, "a", original);
    // The pre-fix shape (`setSessions(prevSnapshot)`, prevSnapshot = [original, b]
    // captured before either operation) would resurrect b here. A wrong
    // VALUE, not a missing symbol — this is the failure HANDOFF.md's scratch
    // reproduction observed against the literal pre-fix rollback closure.
    expect(result).toEqual([original]);
    expect(result.some((s) => s.id === "b")).toBe(false);
  });

  it("rollbackEditSession is a no-op when there is nothing to restore from", () => {
    const other = makeSession({ id: "b" });
    expect(rollbackEditSession([other], "a", undefined)).toEqual([other]);
  });

  it("rollbackRemoveSession reinserts the removed row, sorted back into place", () => {
    const removed = makeSession({ id: "a", date: "2026-07-18" });
    const c = makeSession({ id: "c", date: "2026-07-20" });
    const result = rollbackRemoveSession([c], removed);
    expect(result.map((s) => s.id)).toEqual(["c", "a"]);
  });

  it("rollbackRemoveSession — PROVED. preserves a concurrent edit to another row, unlike a whole-list snapshot restore", () => {
    const removed = makeSession({ id: "b" });
    const editedA = makeSession({ id: "a", note: "edited while b's delete was in flight" });
    // The list as it stands AT ROLLBACK TIME: a has already been edited by a
    // concurrent, already-succeeded editSession.
    const currentList = [editedA];
    const result = rollbackRemoveSession(currentList, removed);
    const a = result.find((s) => s.id === "a");
    // The pre-fix shape would have restored the PRE-edit `a` from its own
    // stale snapshot, silently discarding the concurrent edit.
    expect(a).toEqual(editedA);
    expect(result.some((s) => s.id === "b")).toBe(true);
  });

  it("rollbackRemoveSession is a no-op with nothing to reinsert", () => {
    const a = makeSession({ id: "a" });
    expect(rollbackRemoveSession([a], undefined)).toEqual([a]);
  });

  it("rollbackRemoveSession does not duplicate if the row is already back", () => {
    const removed = makeSession({ id: "a" });
    const already = makeSession({ id: "a", note: "re-added some other way" });
    expect(rollbackRemoveSession([already], removed)).toEqual([already]);
  });
});

describe("applySetPhaseOptimistic / rollbackSetPhase", () => {
  it("applySetPhaseOptimistic maps the target phase id and today's date into the next snapshot", () => {
    const result = applySetPhaseOptimistic("strength", "2026-07-26");
    expect(result).toEqual<PhaseSnapshot>({
      currentPhase: "strength",
      phaseStartDate: "2026-07-26",
    });
  });

  it("rollbackSetPhase restores the pre-mutation snapshot's fields exactly", () => {
    const prev: PhaseSnapshot = {
      currentPhase: "capacity",
      phaseStartDate: "2026-06-01",
    };
    const result = rollbackSetPhase(prev);
    expect(result).toEqual(prev);
  });

  it("apply then rollback round-trips back to the original snapshot", () => {
    const prev: PhaseSnapshot = {
      currentPhase: "capacity",
      phaseStartDate: "2026-06-01",
    };
    const applied = applySetPhaseOptimistic("strength", "2026-07-26");
    expect(applied).not.toEqual(prev);
    const rolledBack = rollbackSetPhase(prev);
    expect(rolledBack).toEqual(prev);
  });
});

describe("sortSessions", () => {
  it("sorts descending by date", () => {
    const list = [
      makeSession({ id: "a", date: "2026-07-01" }),
      makeSession({ id: "b", date: "2026-07-20" }),
      makeSession({ id: "c", date: "2026-07-10" }),
    ];
    expect(sortSessions(list).map((s) => s.id)).toEqual(["b", "c", "a"]);
  });

  it("handles a same-date tie without crashing (stable-ish, both rows present)", () => {
    const list = [
      makeSession({ id: "a", date: "2026-07-10" }),
      makeSession({ id: "b", date: "2026-07-10" }),
    ];
    const result = sortSessions(list);
    expect(result).toHaveLength(2);
    expect(result.map((s) => s.id).sort()).toEqual(["a", "b"]);
  });
});
