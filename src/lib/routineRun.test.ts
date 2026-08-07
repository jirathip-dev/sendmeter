import { afterEach, describe, expect, it, vi } from "vitest";
import {
  classifyElapsed,
  clearRoutineRun,
  elapsedS,
  isAbandoned,
  loadRoutineRun,
  loggedMinutes,
  partialMinutes,
  realElapsedS,
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
  // "Just seen at start" — a sensible default for tests that aren't
  // exercising staleness/heartbeat behavior specifically.
  lastSeenMs: 1_000_000,
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

describe("realElapsedS", () => {
  /// #483 review F4: RoutineFullscreen fast-forwards `elapsed` (and thus
  /// position/done) by `skippedS` on purpose so Skip can reach the end
  /// sooner — but a LOGGED duration must reflect real seconds spent, not
  /// fast-forwarded ones. realElapsedS is elapsedS's real-time counterpart:
  /// same formula, no `+ skippedS` term.
  it("excludes skipped seconds unlike elapsedS", () => {
    const s = { ...base, skippedS: 500 };
    const nowMs = base.startedMs + 30_000;
    expect(elapsedS(s, nowMs)).toBe(530); // position: real 30s + 500 skipped
    expect(realElapsedS(s, nowMs)).toBe(30); // duration to log: real 30s only
  });

  it("still freezes while paused and subtracts pause time, same as elapsedS", () => {
    const s = { ...base, pausedAtMs: base.startedMs + 20_000, pausedTotalMs: 5_000, skippedS: 100 };
    expect(realElapsedS(s, base.startedMs + 999_000)).toBe(15); // (20s - 5s paused)
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

  /// #483 review F6: the function's own comment claims the clamp "must hold
  /// no matter what elapsed value a caller passes in", and the test above is
  /// named "never past it" — but before this fix, `Math.min(600,
  /// Math.max(1, Math.round(NaN / 60)))` is `NaN` (Math.max/min propagate a
  /// NaN argument), which is neither 1..600 nor anything insertSession could
  /// safely receive. This test fails on the pre-F6 implementation with
  /// `expected NaN to be 1` — a real assertion, not a missing symbol.
  it("never returns NaN, even for a non-finite elapsed", () => {
    expect(partialMinutes(NaN)).toBe(1);
    expect(partialMinutes(Infinity)).toBe(600);
    expect(partialMinutes(-Infinity)).toBe(1);
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
/// or paused one. `isAbandoned` alone is necessary but not sufficient — see
/// `resolveRoutineResume` below for how the review's F1/F5 findings against
/// this predicate on its own are actually closed.
describe("isAbandoned", () => {
  const run: RoutineRunState = { ...base };
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

describe("classifyElapsed", () => {
  const totalS = 9 * 60; // 540s

  it("counts elapsed at (or within margin of) the total as completed", () => {
    expect(classifyElapsed(540, totalS)).toEqual({ kind: "completed", durationMin: 9 });
    expect(classifyElapsed(533, totalS)).toEqual({ kind: "completed", durationMin: 9 }); // within the 10s margin
  });

  it("counts a shorter, still-substantial elapsed as partial", () => {
    expect(classifyElapsed(120, totalS)).toEqual({ kind: "partial", durationMin: 2 });
  });

  it("discards anything under the shouldLog bar", () => {
    expect(classifyElapsed(30, totalS)).toEqual({ kind: "discarded" });
    expect(classifyElapsed(0, totalS)).toEqual({ kind: "discarded" });
  });
});

/// #483 review: the actual RoutineCard mount decision. Before this fix, the
/// mount effect's condition was `resumeRun && list.some((p) => p.id ===
/// resumeRun.presetId)` — no elapsed/total check at all, reproduced below
/// (byte-for-byte, as the old inline expression) to prove it would resume an
/// abandoned run. That unconditional resume is exactly what fed a stale
/// `startedMs` into RoutineFullscreen, made `done` true on the very first
/// render, and fired `onFinish` with no user present.
describe("resolveRoutineResume", () => {
  const steps: RoutineStep[] = [{ label: "Warm up", s: 9 * 60 }]; // 9-minute preset, TOTAL_S = 540
  const presets = [{ id: "p1", steps }];
  const totalS = 9 * 60;

  /// Pre-#483 RoutineCard.tsx:107, reproduced verbatim as a local predicate.
  function preFixWouldResume(r: RoutineRunState | null, list: { id: string }[]): boolean {
    return Boolean(r && list.some((p) => p.id === r.presetId));
  }

  it("no run persisted → nothing to resume", () => {
    expect(resolveRoutineResume(null, presets, base.startedMs)).toEqual({ kind: "none" });
  });

  it("preset was deleted → discarded silently, not resumed (unchanged behavior)", () => {
    expect(resolveRoutineResume(base, [], base.startedMs)).toEqual({ kind: "none" });
  });

  it("genuinely in-progress run resumes", () => {
    const run: RoutineRunState = { ...base, lastSeenMs: base.startedMs + 119_000 };
    const nowMs = base.startedMs + 2 * 60 * 1000; // 2 minutes into a 9-minute preset, heartbeat 1s old
    expect(preFixWouldResume(run, presets)).toBe(true); // old code also resumed here — fine
    expect(resolveRoutineResume(run, presets, nowMs)).toEqual({ kind: "resume", presetId: "p1" });
  });

  it("a paused run resumes even read back hours later (must not regress)", () => {
    const paused: RoutineRunState = { ...base, pausedAtMs: base.startedMs + 60_000 };
    const nowMs = base.startedMs + 5 * 60 * 60 * 1000; // read back 5h later
    expect(resolveRoutineResume(paused, presets, nowMs)).toEqual({ kind: "resume", presetId: "p1" });
  });

  /// #483 review F1 (HIGH): a genuinely COMPLETED routine, reclaimed right at
  /// the end, must not be silently discarded — the pre-review fix's
  /// `isAbandoned` predicate could not tell this apart from "abandoned at
  /// minute 2", both reading `elapsed >= totalS`. Reproduces the reviewer's
  /// own numbers: reclaimed 1s before the 540s total (last heartbeat ~537s
  /// in), reopened 30s later.
  it("a run present through (near) the end, reopened shortly after, logs as completed — not discarded (F1)", () => {
    const run: RoutineRunState = { ...base, lastSeenMs: base.startedMs + 537_000 };
    const nowMs = base.startedMs + 575_000; // reclaimed near t=539s, reopened 30s later
    // Pre-review-round fix: isAbandoned(run, totalS, nowMs) is true, and the
    // implementer's fix discarded unconditionally here — nothing logged.
    expect(isAbandoned(run, totalS, nowMs)).toBe(true);
    expect(resolveRoutineResume(run, presets, nowMs)).toEqual({
      kind: "completed",
      durationMin: 9,
      presetId: "p1",
    });
  });

  /// #483 review F5 (MED): a run truly abandoned partway through must not
  /// resume just because wall clock hasn't technically crossed the total yet
  /// — reopening at totalS-1s previously resumed and would log the routine's
  /// full nominal duration one tick later. Reproduces the reviewer's exact
  /// scenario: abandoned at minute 2 (last heartbeat there), reopened at
  /// totalS - 1s.
  it("a run abandoned partway through, reopened just under the total, is NOT resumed — logs the real partial instead (F5)", () => {
    const run: RoutineRunState = { ...base, lastSeenMs: base.startedMs + 120_000 };
    const nowMs = base.startedMs + (totalS - 1) * 1000; // 8:59 after start
    // The pre-review-round fix's isAbandoned check alone says "still in
    // progress" here (elapsed < totalS) — this is exactly the residual bug
    // F5 named: it would have resumed, then logged 9 minutes one tick later.
    expect(isAbandoned(run, totalS, nowMs)).toBe(false);
    const outcome = resolveRoutineResume(run, presets, nowMs);
    expect(outcome.kind).not.toBe("resume");
    expect(outcome).toEqual({ kind: "partial", durationMin: 2, presetId: "p1" });
  });

  it("a run barely touched before going stale is discarded, not resumed or logged (visibly, by the caller)", () => {
    const run: RoutineRunState = { ...base, lastSeenMs: base.startedMs + 5_000 };
    const nowMs = base.startedMs + 2 * 60 * 60 * 1000; // 2h later, only 5s ever confirmed
    expect(resolveRoutineResume(run, presets, nowMs)).toEqual({ kind: "discarded", presetId: "p1" });
  });

  it("an abandoned run (reopened 2h after a 9-minute preset, no heartbeat since minute 2) logs the confirmed partial, not the full total", () => {
    const run: RoutineRunState = { ...base, lastSeenMs: base.startedMs + 120_000 };
    const nowMs = base.startedMs + 2 * 60 * 60 * 1000;
    // The bug: the pre-#483 inline condition has no time check at all, so it
    // would have resumed this run unconditionally.
    expect(preFixWouldResume(run, presets)).toBe(true);
    expect(resolveRoutineResume(run, presets, nowMs)).toEqual({
      kind: "partial",
      durationMin: 2,
      presetId: "p1",
    });
  });

  /// #483 review F4: Skip must not inflate what a stale/abandoned run logs.
  it("a heartbeat's skippedS is not credited when logging a stale run's partial (F4)", () => {
    // Real time seen: 30s. Skip fast-forwarded position by 400s at that same
    // instant (so elapsedS would read 430s — past the "partial" cutoff —
    // while realElapsedS correctly reads 30s).
    const run: RoutineRunState = { ...base, skippedS: 400, lastSeenMs: base.startedMs + 30_000 };
    const nowMs = base.startedMs + 2 * 60 * 60 * 1000;
    const outcome = resolveRoutineResume(run, presets, nowMs);
    // If skippedS were (wrongly) credited, elapsedS(run, lastSeenMs) = 430s,
    // which clears the completed-margin (530s) only barely-not, but clears
    // "partial" heavily inflated vs. the true 30s actually spent.
    expect(outcome).toEqual({ kind: "discarded", presetId: "p1" });
  });

  /// #483 re-review N3: a record from before `lastSeenMs` existed — as
  /// loadRoutineRun would produce for a pre-deploy dangling record, defaulting
  /// the missing field to `startedMs` (never `Date.now()`) — must not
  /// classify a truly-abandoned legacy run as "completed". Reproduces the
  /// reviewer's exact numbers: a 9-minute preset abandoned 2h before this
  /// deploy, with no heartbeat history at all.
  it("a legacy record with no heartbeat history (lastSeenMs defaulted to startedMs) does not fabricate a completed session", () => {
    const legacy: RoutineRunState = { ...base, lastSeenMs: base.startedMs }; // loadRoutineRun's default for a pre-#483-heartbeat record
    const nowMs = base.startedMs + 2 * 60 * 60 * 1000; // 2h later, at deploy time
    expect(resolveRoutineResume(legacy, presets, nowMs)).toEqual({ kind: "discarded", presetId: "p1" });
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
  vi.useRealTimers();
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
      lastSeenMs: 1_015_000,
    };
    saveRoutineRun(run);
    expect(loadRoutineRun()).toEqual(run);
  });

  it("returns null when nothing was persisted (a fresh, non-resuming mount)", () => {
    const { storage } = fakeStorage();
    vi.stubGlobal("localStorage", storage);
    expect(loadRoutineRun()).toBeNull();
  });

  /// #483 re-review N3: a record written before `lastSeenMs` existed has no
  /// heartbeat history at all — defaulting it to `Date.now()` ("just seen")
  /// sounds safe but is backwards: for a legacy record that was actually
  /// abandoned hours before this deploy, it makes the staleness gate read as
  /// fresh, so the huge stale wall-clock elapsed gets trusted and
  /// classifyElapsed reports "completed" — a fabricated full-length session,
  /// once, on the very deploy transition this field exists to prevent (the
  /// review verified this numerically: a 2h-abandoned 9-minute legacy record
  /// classified as `{kind:"completed", durationMin:9}`). Defaulting to
  /// `startedMs` instead is the honest "no evidence beyond the start", which
  /// this test proves by keeping `loadRoutineRun` itself pure (no `Date.now`
  /// stubbing needed at all any more).
  it("defaults a missing lastSeenMs to startedMs, not to now", () => {
    const { storage, map } = fakeStorage();
    vi.stubGlobal("localStorage", storage);
    map.set("sendmeter:routine-run", JSON.stringify({ presetId: "p1", startedMs: 1_000_000 }));
    expect(loadRoutineRun()).toEqual(base); // base.lastSeenMs === base.startedMs
  });

  it("defaults the other optional clock fields so a partial record still resumes", () => {
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

  it("a resumed run's elapsed time still drives the ≥60s partial-log threshold", () => {
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
