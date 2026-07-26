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
  applyAddSessionOptimistic,
  applyEditSessionOptimistic,
  createGenerationGuard,
  reconcileAddSession,
  rollbackAddSession,
  runFetchAttempts,
  sortSessions,
  withOptimisticUpdate,
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
    const deps = baseDeps({ fetchAll });
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
  });

  it("fails all three attempts and surfaces the final error", async () => {
    const fetchAll = vi.fn().mockRejectedValue(new Error("boom"));
    const deps = baseDeps({ fetchAll });
    await runFetchAttempts(deps);
    expect(fetchAll).toHaveBeenCalledTimes(3);
    expect(deps.onSuccess).not.toHaveBeenCalled();
    expect(deps.onError).toHaveBeenCalledTimes(1);
    expect(deps.onError).toHaveBeenCalledWith("boom");
    expect(deps.refreshSession).toHaveBeenCalledTimes(2);
    expect(deps.delay).toHaveBeenCalledTimes(2);
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

    const result = await withOptimisticUpdate({
      apply: vi.fn(),
      action: async () => {
        throw new Error("specific failure");
      },
      onSuccess,
      rollback,
      onError,
      fallbackMessage: "fallback",
    });

    expect(rollback).toHaveBeenCalledTimes(1);
    expect(onError).toHaveBeenCalledWith("specific failure");
    expect(onSuccess).not.toHaveBeenCalled();
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
