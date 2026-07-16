import { describe, it, expect } from "vitest";
import { protocolDurationS, protocolPhaseAt, repSide } from "./protocol";
import type { TindeqPreset } from "../types";

// Classic repeaters: 7s hang / 3s rest × 6 reps, 3 sets, 180s between sets.
const repeaters: TindeqPreset = {
  id: "p1",
  name: "Repeaters",
  holdS: 7,
  reps: 6,
  sets: 3,
  restRepsS: 3,
  restSetsS: 180,
  targetKg: null,
  alternateSides: false,
};

describe("repSide", () => {
  it("alternates left/right per rep", () => {
    expect(repSide(1)).toBe("left");
    expect(repSide(2)).toBe("right");
    expect(repSide(3)).toBe("left");
  });
});

describe("protocolDurationS", () => {
  it("sums holds, rep rests, and set rests", () => {
    // set work = 6*7 + 5*3 = 57; total = 3*57 + 2*180 = 531
    expect(protocolDurationS(repeaters)).toBe(531);
  });
});

describe("protocolPhaseAt", () => {
  it("starts holding rep 1 set 1", () => {
    expect(protocolPhaseAt(repeaters, 0)).toEqual({
      phase: "hold",
      remaining: 7,
      rep: 1,
      set: 1,
    });
  });

  it("transitions hold → rest inside a rep", () => {
    expect(protocolPhaseAt(repeaters, 7).phase).toBe("rest");
    expect(protocolPhaseAt(repeaters, 7).remaining).toBe(3);
    expect(protocolPhaseAt(repeaters, 9.5)).toMatchObject({
      phase: "rest",
      rep: 1,
    });
  });

  it("advances reps", () => {
    // rep 2 hold starts at 10s
    expect(protocolPhaseAt(repeaters, 10)).toMatchObject({
      phase: "hold",
      rep: 2,
      set: 1,
    });
  });

  it("last rep of a set has no rep-rest — goes straight to set rest", () => {
    // set 1 work ends at 57s
    expect(protocolPhaseAt(repeaters, 56.5)).toMatchObject({
      phase: "hold",
      rep: 6,
      set: 1,
    });
    const atSetRest = protocolPhaseAt(repeaters, 57);
    expect(atSetRest.phase).toBe("setRest");
    expect(atSetRest.remaining).toBe(180);
  });

  it("starts set 2 after the set rest", () => {
    // set 2 begins at 57+180 = 237
    expect(protocolPhaseAt(repeaters, 237)).toMatchObject({
      phase: "hold",
      rep: 1,
      set: 2,
    });
  });

  it("is done at the total duration (no trailing set rest)", () => {
    expect(protocolPhaseAt(repeaters, 531).phase).toBe("done");
    expect(protocolPhaseAt(repeaters, 530.5)).toMatchObject({
      phase: "hold",
      rep: 6,
      set: 3,
    });
  });

  it("handles single-rep single-set presets (max hangs)", () => {
    const max: TindeqPreset = {
      id: "p2",
      name: "Max",
      holdS: 10,
      reps: 1,
      sets: 1,
      restRepsS: 0,
      restSetsS: 0,
      targetKg: null,
      alternateSides: false,
    };
    expect(protocolDurationS(max)).toBe(10);
    expect(protocolPhaseAt(max, 5)).toMatchObject({ phase: "hold", rep: 1, set: 1 });
    expect(protocolPhaseAt(max, 10).phase).toBe("done");
  });
});
