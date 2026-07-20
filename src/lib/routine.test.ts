import { describe, it, expect } from "vitest";
import { expandRoutine, routineDurationS } from "./routine";

describe("expandRoutine (SL-83)", () => {
  it("expands steps ×reps with rests BETWEEN repetitions only", () => {
    const segs = expandRoutine([
      { label: "Pull-ups", s: 30, reps: 3, restS: 60 },
      { label: "Stretch", s: 45 },
    ]);
    expect(segs.map((s) => `${s.kind}:${s.durS}`)).toEqual([
      "work:30", "rest:60", "work:30", "rest:60", "work:30", // no rest after last rep
      "work:45",
    ]);
    expect(routineDurationS(segs)).toBe(3 * 30 + 2 * 60 + 45);
    expect(segs[2]).toMatchObject({ rep: 2, reps: 3, stepIndex: 1 });
    expect(segs[5]).toMatchObject({ label: "Stretch", stepIndex: 2, rep: 1 });
  });

  it("prepends a prepare segment and treats old steps as 1 rep, 0 rest", () => {
    const segs = expandRoutine([{ label: "Jog", s: 120 }], { prepareS: 5 });
    expect(segs[0]).toMatchObject({ kind: "prepare", durS: 5, startS: 0 });
    expect(segs[1]).toMatchObject({ kind: "work", startS: 5, durS: 120 });
    expect(routineDurationS(segs)).toBe(125);
  });

  it("skips zero rests", () => {
    const segs = expandRoutine([{ label: "A", s: 10, reps: 2, restS: 0 }]);
    expect(segs.map((s) => s.kind)).toEqual(["work", "work"]);
  });
});
