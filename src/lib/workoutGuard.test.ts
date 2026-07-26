import { describe, expect, it } from "vitest";
import {
  phoneWorkoutBlockedReason,
  routineBlockedReason,
  type WorkoutTabActivity,
} from "./workoutGuard";

const idle: WorkoutTabActivity = {
  liveWorkout: false,
  phoneWorkout: false,
  routine: false,
};

describe("routineBlockedReason (#222)", () => {
  it("allows a routine when nothing else is running", () => {
    expect(routineBlockedReason(idle)).toBeNull();
  });

  it("blocks while a phone workout is running", () => {
    expect(routineBlockedReason({ ...idle, phoneWorkout: true })).toBe(
      "Finish your workout first",
    );
  });

  it("blocks while a live watch workout is running", () => {
    expect(routineBlockedReason({ ...idle, liveWorkout: true })).toBe(
      "Finish your watch workout first",
    );
  });

  it("names the watch when both are somehow active", () => {
    // WorkoutView hides the phone card entirely while the watch is live, so
    // the watch is the reason the user can actually act on.
    expect(
      routineBlockedReason({ ...idle, liveWorkout: true, phoneWorkout: true }),
    ).toBe("Finish your watch workout first");
  });

  it("does not block a routine just because a routine is running", () => {
    // The already-running routine owns the fullscreen; the card's Start button
    // isn't reachable, and auto-resume must never be gated on this verdict.
    expect(routineBlockedReason({ ...idle, routine: true })).toBeNull();
  });

  it("always returns a reason string when it blocks — never a dead button", () => {
    for (const a of [
      { ...idle, phoneWorkout: true },
      { ...idle, liveWorkout: true },
    ]) {
      expect(routineBlockedReason(a)).toBeTruthy();
    }
  });
});

describe("phoneWorkoutBlockedReason (#222)", () => {
  it("allows a workout when nothing else is running", () => {
    expect(phoneWorkoutBlockedReason(idle)).toBeNull();
  });

  it("blocks while a routine is running", () => {
    expect(phoneWorkoutBlockedReason({ ...idle, routine: true })).toBe(
      "Finish your routine first",
    );
  });

  it("is unaffected by workout state (the card is hidden/resumed instead)", () => {
    expect(
      phoneWorkoutBlockedReason({ ...idle, liveWorkout: true, phoneWorkout: true }),
    ).toBeNull();
  });
});

describe("the two guards can't deadlock each other", () => {
  it("never blocks both directions from an idle tab", () => {
    expect(routineBlockedReason(idle)).toBeNull();
    expect(phoneWorkoutBlockedReason(idle)).toBeNull();
  });

  it("blocks exactly one direction once something is running", () => {
    const running: WorkoutTabActivity = { ...idle, routine: true };
    expect(phoneWorkoutBlockedReason(running)).toBeTruthy();
    expect(routineBlockedReason(running)).toBeNull();

    const workout: WorkoutTabActivity = { ...idle, phoneWorkout: true };
    expect(routineBlockedReason(workout)).toBeTruthy();
    expect(phoneWorkoutBlockedReason(workout)).toBeNull();
  });
});
