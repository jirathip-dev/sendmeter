import { afterEach, describe, expect, it, vi } from "vitest";
import {
  clearRoutineRun,
  elapsedS,
  loadRoutineRun,
  partialMinutes,
  saveRoutineRun,
  shouldLog,
  type RoutineRunState,
} from "./routineRun";

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
