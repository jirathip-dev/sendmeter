import { describe, expect, it } from "vitest";
import {
  elapsedS,
  partialMinutes,
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
