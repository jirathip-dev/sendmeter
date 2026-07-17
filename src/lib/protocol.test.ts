import { describe, it, expect } from "vitest";
import {
  buildTimeline,
  protocolDurationS,
  repSide,
  timelineAt,
  timelineDurationS,
} from "./protocol";
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

// The user's example: 5s holds, 30s rest, alternating hands.
const alt: TindeqPreset = {
  id: "p2",
  name: "Alt",
  holdS: 5,
  reps: 2,
  sets: 1,
  restRepsS: 30,
  restSetsS: 0,
  targetKg: null,
  alternateSides: true,
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

describe("buildTimeline — single side", () => {
  const tl = buildTimeline(repeaters);

  it("matches the nominal duration", () => {
    expect(timelineDurationS(tl)).toBe(531);
  });

  it("starts holding rep 1 set 1", () => {
    const pos = timelineAt(tl, 0)!;
    expect(pos.seg).toMatchObject({ phase: "hold", rep: 1, set: 1, side: null });
    expect(pos.remaining).toBe(7);
  });

  it("transitions hold → rest → next rep", () => {
    expect(timelineAt(tl, 7)!.seg.phase).toBe("rest");
    expect(timelineAt(tl, 10)!.seg).toMatchObject({ phase: "hold", rep: 2 });
  });

  it("last rep of a set goes straight to set rest", () => {
    // set 1 work ends at 57s
    expect(timelineAt(tl, 56.5)!.seg).toMatchObject({ phase: "hold", rep: 6, set: 1 });
    const pos = timelineAt(tl, 57)!;
    expect(pos.seg.phase).toBe("setRest");
    expect(pos.remaining).toBe(180);
    expect(timelineAt(tl, 237)!.seg).toMatchObject({ phase: "hold", rep: 1, set: 2 });
  });

  it("is done at the total duration", () => {
    expect(timelineAt(tl, 531)).toBeNull();
    expect(timelineAt(tl, 530.5)!.seg).toMatchObject({ phase: "hold", rep: 6, set: 3 });
  });

  it("prepends a prepare segment when asked", () => {
    const withPrep = buildTimeline(repeaters, { prepareS: 5 });
    expect(timelineAt(withPrep, 2)!.seg.phase).toBe("prepare");
    expect(timelineAt(withPrep, 5)!.seg).toMatchObject({ phase: "hold", rep: 1 });
    expect(timelineDurationS(withPrep)).toBe(536);
  });
});

describe("buildTimeline — alternating sides", () => {
  // 5s hold / 30s rest: L 5s → switch 3s → R 5s → rest 19s → switch back 3s
  const tl = buildTimeline(alt, { switchS: 3 });

  it("runs L hold, switch, R hold inside the rest, then the remainder", () => {
    expect(timelineAt(tl, 0)!.seg).toMatchObject({ phase: "hold", side: "left", rep: 1 });
    const sw = timelineAt(tl, 5)!;
    expect(sw.seg.phase).toBe("switch");
    expect(sw.remaining).toBe(3);
    expect(timelineAt(tl, 8)!.seg).toMatchObject({ phase: "hold", side: "right", rep: 1 });
    const rest = timelineAt(tl, 13)!;
    expect(rest.seg.phase).toBe("rest");
    expect(rest.remaining).toBe(19); // 30 - 3 - 5 - 3 (switch back)
  });

  it("counts down the switch BACK to left before the next pair", () => {
    const back = timelineAt(tl, 32)!;
    expect(back.seg).toMatchObject({ phase: "switch", side: "left" });
    expect(back.remaining).toBe(3);
    expect(timelineAt(tl, 35)!.seg).toMatchObject({ phase: "hold", side: "left", rep: 2 });
    // rep 2: L 35-40, switch 40-43, R 43-48, done — total unchanged
    expect(timelineDurationS(tl)).toBe(48);
    expect(timelineAt(tl, 48)).toBeNull();
  });

  it("auto-extends a rest too short for the other hand's hold + switches", () => {
    // 7:3 repeaters alternating: rest 3 < 3+7+3 → effective rest 13 →
    // zero idle rest, continuous L/switch/R/switch/L…
    const cont = buildTimeline(
      { ...repeaters, sets: 1, reps: 2, alternateSides: true },
      { switchS: 3 },
    );
    // L 0-7, switch 7-10, R 10-17, switch-back 17-20, L 20-27 …
    expect(timelineAt(cont, 17)!.seg).toMatchObject({ phase: "switch", side: "left" });
    expect(timelineAt(cont, 20)!.seg).toMatchObject({ phase: "hold", side: "left", rep: 2 });
    expect(timelineDurationS(cont)).toBe(37);
  });

  it("set rest also fits the pair and ends with a switch back", () => {
    const twoSets = buildTimeline(
      { ...alt, sets: 2, restSetsS: 60 },
      { switchS: 3 },
    );
    // set 1 ends after rep2 R hold at 48; setRest = 60-3-5-3 = 49, then
    // switch back 3 → set 2 starts at 100
    const pos = timelineAt(twoSets, 48)!;
    expect(pos.seg.phase).toBe("setRest");
    expect(pos.remaining).toBe(49);
    expect(timelineAt(twoSets, 98)!.seg).toMatchObject({ phase: "switch", side: "left" });
    expect(timelineAt(twoSets, 100)!.seg).toMatchObject({
      phase: "hold",
      side: "left",
      rep: 1,
      set: 2,
    });
  });
});
