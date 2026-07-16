import { describe, it, expect } from "vitest";
import { phoneWorkoutReducer, type PhoneWorkoutState } from "./phoneWorkout";

const T0 = "2026-07-16T10:00:00.000Z";
const T1 = "2026-07-16T10:01:00.000Z";
const T2 = "2026-07-16T10:01:30.000Z";
const T3 = "2026-07-16T10:05:00.000Z";

const idle: PhoneWorkoutState = { phase: "idle" };

describe("phoneWorkoutReducer", () => {
  it("start → running with no attempts, resting", () => {
    const s = phoneWorkoutReducer(idle, { type: "start", at: T0 });
    expect(s).toEqual({
      phase: "running",
      startedAt: T0,
      attempts: [],
      climbingSince: null,
    });
  });

  it("beginBoulder / endBoulder logs an attempt with the wall-clock duration", () => {
    let s = phoneWorkoutReducer(idle, { type: "start", at: T0 });
    s = phoneWorkoutReducer(s, { type: "beginBoulder", at: T1 });
    expect(s.phase === "running" && s.climbingSince).toBe(T1);
    s = phoneWorkoutReducer(s, { type: "endBoulder", at: T2 });
    expect(s.phase === "running" && s.attempts).toEqual([
      { startedAt: T1, durationS: 30 },
    ]);
    expect(s.phase === "running" && s.climbingSince).toBeNull();
  });

  it("ignores invalid transitions (double begin, rest while resting, start mid-run)", () => {
    let s = phoneWorkoutReducer(idle, { type: "start", at: T0 });
    const resting = s;
    s = phoneWorkoutReducer(s, { type: "endBoulder", at: T1 }); // not climbing
    expect(s).toBe(resting);
    s = phoneWorkoutReducer(s, { type: "beginBoulder", at: T1 });
    const climbing = s;
    s = phoneWorkoutReducer(s, { type: "beginBoulder", at: T2 }); // already climbing
    expect(s).toBe(climbing);
    expect(phoneWorkoutReducer(climbing, { type: "start", at: T2 })).toBe(climbing);
  });

  it("end closes an open attempt at the end time", () => {
    let s = phoneWorkoutReducer(idle, { type: "start", at: T0 });
    s = phoneWorkoutReducer(s, { type: "beginBoulder", at: T1 });
    s = phoneWorkoutReducer(s, { type: "end", at: T2 });
    expect(s.phase).toBe("confirming");
    if (s.phase === "confirming") {
      expect(s.attempts).toEqual([{ startedAt: T1, durationS: 30 }]);
      expect(s.endedAt).toBe(T2);
    }
  });

  it("end while resting keeps the logged attempts as-is", () => {
    let s = phoneWorkoutReducer(idle, { type: "start", at: T0 });
    s = phoneWorkoutReducer(s, { type: "beginBoulder", at: T1 });
    s = phoneWorkoutReducer(s, { type: "endBoulder", at: T2 });
    s = phoneWorkoutReducer(s, { type: "end", at: T3 });
    if (s.phase === "confirming") {
      expect(s.attempts).toHaveLength(1);
      expect(s.startedAt).toBe(T0);
      expect(s.endedAt).toBe(T3);
    } else {
      expect.unreachable();
    }
  });

  it("attempt duration floors at 1s (accidental double-tap)", () => {
    let s = phoneWorkoutReducer(idle, { type: "start", at: T0 });
    s = phoneWorkoutReducer(s, { type: "beginBoulder", at: T1 });
    s = phoneWorkoutReducer(s, { type: "endBoulder", at: T1 });
    expect(s.phase === "running" && s.attempts[0]!.durationS).toBe(1);
  });

  it("reset returns to idle from any phase", () => {
    let s = phoneWorkoutReducer(idle, { type: "start", at: T0 });
    s = phoneWorkoutReducer(s, { type: "end", at: T1 });
    expect(phoneWorkoutReducer(s, { type: "reset" })).toEqual(idle);
  });
});
