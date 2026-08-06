import { afterEach, describe, expect, it, vi } from "vitest";
import {
  clearRoutineRun,
  elapsedS,
  isAbandoned,
  loadRoutineRun,
  loggedMinutes,
  partialMinutes,
  resolveRoutineResume,
  saveRoutineRun,
  shouldLog,
  type RoutineRunState,
} from "./routineRun";
import type { RoutineStep } from "../types";

const base: RoutineRunState = {
  presetId: "p1",
  startedMs: 1_000_000,
  skippedS: 0,
  pausedAtMs: null,
  pausedTotalMs: 0,
};

describe("elapsedS", () => {
  it("counts wall-clock seconds since start", () => {
    expect(elapsedS(base, 1_000_000 + 30_000)).toBe(30);
  });

  it("adds skipped seconds", () => {
    expect(elapsedS({ ...base, skippedS: 12 }, 1_000_000 + 30_000)).toBe(42);
  });

  it("subtracts accumulated pause time", () => {
    // 30s wall-clock, 8s of it spent paused → 22s of routine time
    expect(elapsedS({ ...base, pausedTotalMs: 8_000 }, 1_000_000 + 30_000)).toBe(22);
  });

  it("freezes while paused (uses pausedAtMs, not now)", () => {
    const s = { ...base, pausedAtMs: 1_000_000 + 20_000 };
    // now keeps advancing but elapsed stays at the pause instant
    expect(elapsedS(s, 1_000_000 + 99_000)).toBe(20);
  });

  it("resume math survives a round-trip through persistence fields", () => {
    // paused at 20s, resumed after a 10s pause, then 5s more → 25s
    const s = { ...base, pausedTotalMs: 10_000 };
    expect(elapsedS(s, 1_000_000 + 35_000)).toBe(25);
  });
});

describe("shouldLog", () => {
  it("is false under a minute", () => {
    expect(shouldLog(0)).toBe(false);
    expect(shouldLog(59.9)).toBe(false);
  });
  it("is true at a minute or more", () => {
    expect(shouldLog(60)).toBe(true);
    expect(shouldLog(600)).toBe(true);
  });
});

describe("partialMinutes", () => {
  it("rounds to whole minutes, floor of 1", () => {
    expect(partialMinutes(60)).toBe(1);
    expect(partialMinutes(89)).toBe(1);
    expect(partialMinutes(90)).toBe(2);
    expect(partialMinutes(150)).toBe(3);
  });

  /// #483: pre-fix this was `Math.max(1, Math.round(elapsed / 60))` with no
  /// upper bound — `partialMinutes(601 * 60)` returned 601, which violates
  /// the sessions table's `duration_min between 1 and 600` check and would
  /// have made `insertSession` reject the row (surfacing as a bare "Failed
  /// to log routine" with the run already discarded). This is the DB's own
  /// range, checked once here, at the one function every logged duration
  /// routes through.
  it("clamps to the DB's duration_min range (1..600), never past it", () => {
    expect(partialMinutes(601 * 60)).toBe(600);
    expect(partialMinutes(24 * 60 * 60)).toBe(600); // a full day, e.g. #483's overnight case
    expect(partialMinutes(0)).toBe(1);
    expect(partialMinutes(-30)).toBe(1);
  });
});

describe("loggedMinutes", () => {
  /// #483's core arithmetic: a 9-minute preset (TOTAL_S = 540) abandoned for
  /// 2 hours. Pre-fix, RoutineFullscreen's finish effect computed
  /// `Math.max(1, Math.round((Date.now() - startedMs) / 60000))` — raw wall
  /// clock since start, uncapped by the routine's own total — which for this
  /// exact scenario is 120: `Math.max(1, Math.round((2 * 60 * 60 * 1000) / 60000))`
  /// below reproduces that pre-fix formula standalone (no RoutineFullscreen
  /// import needed) to prove the old value really was 120, then shows
  /// loggedMinutes caps it at the routine's own 9 minutes instead.
  it("caps a 2h-abandoned 9-minute routine at 9 minutes, not the 120 the old formula gave", () => {
    const startedMs = 1_000_000;
    const nowMs = startedMs + 2 * 60 * 60 * 1000; // reopened 2h later
    const totalS = 9 * 60; // 9-minute preset
    const elapsed = (nowMs - startedMs) / 1000; // no pause/skip in play — matches elapsedS here

    const preFixFormula = Math.max(1, Math.round((nowMs - startedMs) / 60000));
    expect(preFixFormula).toBe(120); // reproduces the issue's own arithmetic

    expect(loggedMinutes(elapsed, totalS)).toBe(9);
  });

  it("still clamps to 600 even for a total that legitimately exceeds it", () => {
    expect(loggedMinutes(1000 * 60, 1000 * 60)).toBe(600);
  });

  it("does not inflate a normal, unexpired completion", () => {
    expect(loggedMinutes(9 * 60, 9 * 60)).toBe(9);
  });
});

/// #483: refusing an abandoned run, without dropping a genuinely in-progress
/// or paused one.
describe("isAbandoned", () => {
  const run: RoutineRunState = {
    presetId: "p1",
    startedMs: 1_000_000,
    skippedS: 0,
    pausedAtMs: null,
    pausedTotalMs: 0,
  };
  const totalS = 9 * 60; // 9-minute preset, matching the issue's example

  it("is not abandoned while genuinely in progress", () => {
    expect(isAbandoned(run, totalS, run.startedMs + 2 * 60 * 1000)).toBe(false);
  });

  it("is abandoned once wall-clock elapsed reaches the routine's total", () => {
    expect(isAbandoned(run, totalS, run.startedMs + totalS * 1000)).toBe(true);
  });

  it("is abandoned when reopened hours after the total should have elapsed (the issue's exact scenario)", () => {
    expect(isAbandoned(run, totalS, run.startedMs + 2 * 60 * 60 * 1000)).toBe(true);
  });

  it("a paused run is never abandoned by stale wall clock — frozen elapsed still governs", () => {
    // Paused at 60s in; read back 2h later. Matches the issue's own claim
    // that pause-then-resume works today and must keep working.
    const paused: RoutineRunState = { ...run, pausedAtMs: run.startedMs + 60_000 };
    expect(isAbandoned(paused, totalS, run.startedMs + 2 * 60 * 60 * 1000)).toBe(false);
  });
});

/// #483: the actual RoutineCard mount decision. Before this fix, the mount
/// effect's condition was `resumeRun && list.some((p) => p.id === resumeRun.presetId)`
/// — no elapsed/total check at all, reproduced below (byte-for-byte, as the
/// old inline expression) to prove it would resume an abandoned run. That
/// unconditional resume is exactly what fed a stale `startedMs` into
/// RoutineFullscreen, made `done` true on the very first render, and fired
/// `onFinish` with no user present.
describe("resolveRoutineResume", () => {
  const steps: RoutineStep[] = [{ label: "Warm up", s: 9 * 60 }]; // 9-minute preset
  const presets = [{ id: "p1", steps }];
  const run: RoutineRunState = {
    presetId: "p1",
    startedMs: 1_000_000,
    skippedS: 0,
    pausedAtMs: null,
    pausedTotalMs: 0,
  };

  /// Pre-#483 RoutineCard.tsx:107, reproduced verbatim as a local predicate.
  function preFixWouldResume(r: RoutineRunState | null, list: { id: string }[]): boolean {
    return Boolean(r && list.some((p) => p.id === r.presetId));
  }

  it("no run persisted → nothing to resume", () => {
    expect(resolveRoutineResume(null, presets, run.startedMs)).toBeNull();
  });

  it("preset was deleted → discarded, not resumed (unchanged behavior)", () => {
    expect(resolveRoutineResume(run, [], run.startedMs)).toBeNull();
  });

  it("genuinely in-progress run resumes", () => {
    const nowMs = run.startedMs + 2 * 60 * 1000; // 2 minutes into a 9-minute preset
    expect(preFixWouldResume(run, presets)).toBe(true); // old code also resumed here — fine
    expect(resolveRoutineResume(run, presets, nowMs)).toBe("p1");
  });

  it("a paused run resumes even read back hours later (must not regress)", () => {
    const paused: RoutineRunState = { ...run, pausedAtMs: run.startedMs + 60_000 };
    const nowMs = run.startedMs + 5 * 60 * 60 * 1000; // read back 5h later
    expect(resolveRoutineResume(paused, presets, nowMs)).toBe("p1");
  });

  it("an abandoned run (reopened 2h after a 9-minute preset) is discarded, not resumed", () => {
    const nowMs = run.startedMs + 2 * 60 * 60 * 1000;
    // The bug: the old inline condition has no time check at all, so it
    // would have resumed this run unconditionally — which is exactly what
    // let a stale `startedMs` reach RoutineFullscreen already `done`.
    expect(preFixWouldResume(run, presets)).toBe(true);
    // The fix: resolveRoutineResume additionally rejects it as abandoned.
    expect(resolveRoutineResume(run, presets, nowMs)).toBeNull();
  });
});

/// In-memory stand-in for localStorage — these tests run in node (no jsdom),
/// matching the "pure logic only" convention for web tests.
function fakeStorage() {
  const map = new Map<string, string>();
  return {
    map,
    storage: {
      getItem: (k: string) => map.get(k) ?? null,
      setItem: (k: string, v: string) => void map.set(k, v),
      removeItem: (k: string) => void map.delete(k),
    },
  };
}

afterEach(() => {
  vi.unstubAllGlobals();
});

/// The auto-resume path RoutineCard runs on mount (SL-97). #222 added a guard
/// on *starting* a routine; resuming an interrupted one must stay untouched,
/// so pin the persistence contract it depends on.
describe("routine run persistence (auto-resume)", () => {
  it("round-trips a run so an interrupted routine resumes where it left off", () => {
    const { storage } = fakeStorage();
    vi.stubGlobal("localStorage", storage);
    const run: RoutineRunState = {
      ...base,
      skippedS: 12,
      pausedAtMs: 1_020_000,
      pausedTotalMs: 5_000,
    };
    saveRoutineRun(run);
    expect(loadRoutineRun()).toEqual(run);
  });

  it("returns null when nothing was persisted (a fresh, non-resuming mount)", () => {
    const { storage } = fakeStorage();
    vi.stubGlobal("localStorage", storage);
    expect(loadRoutineRun()).toBeNull();
  });

  it("defaults the optional clock fields so a partial record still resumes", () => {
    const { storage, map } = fakeStorage();
    vi.stubGlobal("localStorage", storage);
    map.set("sendmeter:routine-run", JSON.stringify({ presetId: "p1", startedMs: 1_000_000 }));
    expect(loadRoutineRun()).toEqual(base);
  });

  it("ignores a malformed or half-written record rather than throwing on mount", () => {
    const { storage, map } = fakeStorage();
    vi.stubGlobal("localStorage", storage);
    map.set("sendmeter:routine-run", "{not json");
    expect(loadRoutineRun()).toBeNull();
    map.set("sendmeter:routine-run", JSON.stringify({ startedMs: 1_000_000 }));
    expect(loadRoutineRun()).toBeNull();
  });

  it("clears the run, so a finished routine doesn't resume on the next mount", () => {
    const { storage } = fakeStorage();
    vi.stubGlobal("localStorage", storage);
    saveRoutineRun(base);
    clearRoutineRun();
    expect(loadRoutineRun()).toBeNull();
  });

  it("survives storage being unavailable entirely (private mode / quota)", () => {
    vi.stubGlobal("localStorage", {
      getItem: () => {
        throw new Error("SecurityError");
      },
      setItem: () => {
        throw new Error("QuotaExceededError");
      },
      removeItem: () => {
        throw new Error("SecurityError");
      },
    });
    expect(() => saveRoutineRun(base)).not.toThrow();
    expect(() => clearRoutineRun()).not.toThrow();
    expect(loadRoutineRun()).toBeNull();
  });

  it("a resumed run's elapsed time still drives the ≥60s partial-log decision", () => {
    const { storage } = fakeStorage();
    vi.stubGlobal("localStorage", storage);
    saveRoutineRun({ ...base, pausedTotalMs: 5_000 });
    const resumed = loadRoutineRun()!;
    // 70s wall-clock minus 5s paused = 65s of routine time → logs 1 min.
    const elapsed = elapsedS(resumed, base.startedMs + 70_000);
    expect(elapsed).toBe(65);
    expect(shouldLog(elapsed)).toBe(true);
    expect(partialMinutes(elapsed)).toBe(1);
  });

  it("a run barely opened resumes but stays below the partial-log threshold", () => {
    const { storage } = fakeStorage();
    vi.stubGlobal("localStorage", storage);
    saveRoutineRun(base);
    const resumed = loadRoutineRun()!;
    expect(shouldLog(elapsedS(resumed, base.startedMs + 20_000))).toBe(false);
  });
});
