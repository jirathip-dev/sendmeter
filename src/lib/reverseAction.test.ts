import { describe, expect, it, vi } from "vitest";
import type { NewTindeqRecording, TindeqSample } from "../types";
import {
  buildReverseActionTimeline,
  buildReverseActionSetRecording,
  buildUnclaimedReverseActionSalvage,
  cadenceMarkersForSet,
  completesReverseActionSetAt,
  parseCadenceMarkers,
  parseReverseActionSetMetrics,
  persistReverseActionSetOnce,
  reverseActionCadenceKey,
  reverseActionSetKey,
  reverseActionSetMetrics,
  reverseActionSetWindow,
  reverseActionTargetBand,
  sliceReverseActionSet,
} from "./reverseAction";

const prescription = {
  reps: 2,
  sets: 2,
  cadenceOutS: 3,
  cadenceReturnS: 2,
  restSetsS: 10,
  prepareS: 5,
};

function recording(id = "set-1"): NewTindeqRecording & { id: string } {
  return {
    id,
    durationMs: 10_000,
    peakKg: 20,
    avgKg: 20,
    note: "",
    tag: "Reverse curl",
    side: "left",
    groupId: "group-1",
    protocolRunId: "run-1",
    setNo: 1,
    zone: "strength",
    samples: [
      { t: 0, kg: 20 },
      { t: 10_000, kg: 20 },
    ],
    protocolMode: "reverse_action",
  };
}

describe("Reverse Action cadence", () => {
  it("expands prepare, continuous OUT/RETURN reps, and inter-set rest", () => {
    expect(buildReverseActionTimeline(prescription)).toEqual([
      { phase: "prepare", side: null, direction: null, rep: 1, set: 1, startS: 0, durS: 5 },
      { phase: "move", side: null, direction: "out", rep: 1, set: 1, startS: 5, durS: 3 },
      { phase: "move", side: null, direction: "return", rep: 1, set: 1, startS: 8, durS: 2 },
      { phase: "move", side: null, direction: "out", rep: 2, set: 1, startS: 10, durS: 3 },
      { phase: "move", side: null, direction: "return", rep: 2, set: 1, startS: 13, durS: 2 },
      { phase: "setRest", side: null, direction: null, rep: 2, set: 1, startS: 15, durS: 10 },
      { phase: "move", side: null, direction: "out", rep: 1, set: 2, startS: 25, durS: 3 },
      { phase: "move", side: null, direction: "return", rep: 1, set: 2, startS: 28, durS: 2 },
      { phase: "move", side: null, direction: "out", rep: 2, set: 2, startS: 30, durS: 3 },
      { phase: "move", side: null, direction: "return", rep: 2, set: 2, startS: 33, durS: 2 },
    ]);
  });

  it("returns one set window and relative cadence/rep markers", () => {
    const timeline = buildReverseActionTimeline(prescription);
    expect(reverseActionSetWindow(timeline, 2)).toEqual({
      startS: 25,
      endS: 35,
      durationS: 10,
    });
    expect(cadenceMarkersForSet(timeline, 2)).toEqual([
      { tMs: 0, rep: 1, direction: "out" },
      { tMs: 3000, rep: 1, direction: "return" },
      { tMs: 5000, rep: 2, direction: "out" },
      { tMs: 8000, rep: 2, direction: "return" },
    ]);
    expect(completesReverseActionSetAt(timeline, 4)).toBe(true);
    expect(completesReverseActionSetAt(timeline, 3)).toBe(false);
    expect(reverseActionCadenceKey(timeline[1]!)).not.toBe(
      reverseActionCadenceKey(timeline[2]!),
    );
  });

  it("slices one continuous raw trace per set and omits unreached markers", () => {
    const timeline = buildReverseActionTimeline(prescription);
    const samples: TindeqSample[] = Array.from({ length: 71 }, (_, index) => ({
      t: index * 500,
      kg: 10 + index / 10,
    }));
    const partial = sliceReverseActionSet(samples, timeline, 2, 31_500);
    expect(partial?.samples[0]).toEqual({ t: 0, kg: 15 });
    expect(partial?.samples.at(-1)).toEqual({ t: 6500, kg: 16.3 });
    expect(partial?.markers).toEqual([
      { tMs: 0, rep: 1, direction: "out" },
      { tMs: 3000, rep: 1, direction: "return" },
      { tMs: 5000, rep: 2, direction: "out" },
    ]);
    expect(partial?.plannedDurationMs).toBe(10_000);
  });

  it("builds one self-describing recording row for a complete set", () => {
    const timeline = buildReverseActionTimeline({ ...prescription, sets: 1 });
    const built = buildReverseActionSetRecording({
      id: "set-1",
      samples: [
        { t: 5_000, kg: 20 },
        { t: 10_000, kg: 20 },
        { t: 15_000, kg: 20 },
      ],
      timeline,
      set: 1,
      targetBand: { kg: 20, lowKg: 18, highKg: 22 },
      cadenceOutS: 3,
      cadenceReturnS: 2,
      base: {
        note: "",
        tag: "Reverse curl",
        side: "left",
        groupId: "group-1",
        protocolRunId: "run-1",
        zone: "strength",
        setupNote: "red spring",
      },
    });
    expect(built).toMatchObject({
      id: "set-1",
      durationMs: 10_000,
      protocolMode: "reverse_action",
      setNo: 1,
      targetKg: 20,
      cadenceMarkers: [
        { tMs: 0, rep: 1, direction: "out" },
        { tMs: 3000, rep: 1, direction: "return" },
        { tMs: 5000, rep: 2, direction: "out" },
        { tMs: 8000, rep: 2, direction: "return" },
      ],
      setupNote: "red spring",
      plannedDurationMs: 10_000,
      actualDurationMs: 10_000,
    });
    expect(built?.setMetrics?.cadenceAdherencePct).toBe(100);
  });

  it("builds a measured set without inventing a force target", () => {
    const timeline = buildReverseActionTimeline({ ...prescription, sets: 1 });
    const built = buildReverseActionSetRecording({
      id: "target-free-set",
      samples: [
        { t: 5_000, kg: 12 },
        { t: 10_000, kg: 14 },
        { t: 15_000, kg: 13 },
      ],
      timeline,
      set: 1,
      targetBand: null,
      cadenceOutS: 3,
      cadenceReturnS: 2,
      base: {
        note: "",
        tag: "Resisted curl",
        side: "left",
        groupId: "group-1",
        protocolRunId: "run-1",
        zone: null,
        setupNote: "red spring",
      },
    });
    expect(built).toMatchObject({
      targetKg: null,
      targetLowKg: null,
      targetHighKg: null,
      protocolMode: "reverse_action",
      avgKg: 13.25,
    });
    expect(built?.setMetrics?.inTargetPct).toBeNull();
    expect(built?.setMetrics?.cadenceAdherencePct).toBe(100);
  });
});

describe("Reverse Action target and set metrics", () => {
  it("resolves percentage and absolute tolerances", () => {
    expect(reverseActionTargetBand(20, "percent", 10)).toEqual({
      kg: 20,
      lowKg: 18,
      highKg: 22,
    });
    expect(reverseActionTargetBand(20, "kg", 1.5)).toEqual({
      kg: 20,
      lowKg: 18.5,
      highKg: 21.5,
    });
    expect(reverseActionTargetBand(null, "percent", 10)).toBeNull();
  });

  it("reports a flat, complete, in-zone set without inventing variability", () => {
    const metrics = reverseActionSetMetrics(
      [
        { t: 0, kg: 20 },
        { t: 2_500, kg: 20 },
        { t: 5_000, kg: 20 },
        { t: 7_500, kg: 20 },
        { t: 10_000, kg: 20 },
      ],
      { kg: 20, lowKg: 18, highKg: 22 },
      10_000,
    );
    expect(metrics).toEqual({
      meanKg: 20,
      coefficientVariationPct: 0,
      inTargetPct: 100,
      timeUnderTensionMs: 10_000,
      driftPct: 0,
      cadenceAdherencePct: 100,
    });
  });

  it("time-weights irregular samples, excludes unloaded time, and exposes drift", () => {
    const metrics = reverseActionSetMetrics(
      [
        { t: 0, kg: 0 },
        { t: 1_000, kg: 0 },
        { t: 2_000, kg: 10 },
        { t: 5_000, kg: 10 },
        { t: 8_000, kg: 15 },
        { t: 10_000, kg: 15 },
      ],
      { kg: 12, lowKg: 9, highKg: 13 },
      10_000,
    );
    expect(metrics.timeUnderTensionMs).toBe(9_000);
    expect(metrics.meanKg).toBeCloseTo(11.39, 2);
    expect(metrics.inTargetPct).toBeCloseTo(66.7, 1);
    expect(metrics.driftPct).toBe(200);
    expect(metrics.cadenceAdherencePct).toBe(100);
  });

  it("describes an early stop as incomplete prescribed cadence, not motion detection", () => {
    const metrics = reverseActionSetMetrics(
      [
        { t: 0, kg: 20 },
        { t: 5_000, kg: 20 },
      ],
      null,
      10_000,
    );
    expect(metrics.cadenceAdherencePct).toBe(50);
    expect(metrics.inTargetPct).toBeNull();
  });
});

describe("Reverse Action stored JSON guards", () => {
  it("accepts the persisted marker/metric shapes and rejects malformed JSON", () => {
    const markers = [{ tMs: 0, rep: 1, direction: "out" as const }];
    expect(parseCadenceMarkers(markers)).toEqual(markers);
    expect(parseCadenceMarkers([{ tMs: -1, rep: 1, direction: "out" }])).toBeNull();
    const metrics = reverseActionSetMetrics(
      [
        { t: 0, kg: 20 },
        { t: 1_000, kg: 20 },
      ],
      null,
      1_000,
    );
    expect(parseReverseActionSetMetrics(metrics)).toEqual(metrics);
    expect(parseReverseActionSetMetrics({ ...metrics, timeUnderTensionMs: "1s" })).toBeNull();
  });
});

describe("Reverse Action exactly-once persistence", () => {
  it("sign-out salvage skips an autosave claim and claims the partial current set once", () => {
    const timeline = buildReverseActionTimeline(prescription);
    const claims = new Set([reverseActionSetKey("run-1", 1)]);
    const ids = new Map<string, string>();
    let nextId = 0;
    const samples = Array.from({ length: 59 }, (_, index) => ({
      t: index * 500,
      kg: 20,
    }));
    const build = () =>
      buildUnclaimedReverseActionSalvage({
        samples,
        timeline,
        sets: 2,
        runId: "run-1",
        claims,
        ids,
        createId: () => `id-${++nextId}`,
        protocolShiftS: 0,
        cadenceOutS: 3,
        cadenceReturnS: 2,
        targetBandForSet: () => ({ kg: 20, lowKg: 18, highKg: 22 }),
        baseForSet: () => ({
          note: "Recovered after sign-out",
          tag: "Reverse curl",
          side: "left",
          groupId: "group-1",
          protocolRunId: "run-1",
          zone: "strength",
          setupNote: "",
        }),
      });

    const first = build();
    expect(first).toHaveLength(1);
    expect(first[0]).toMatchObject({ setNo: 2, id: "id-1" });
    expect(first[0]!.setMetrics?.cadenceAdherencePct).toBe(40);
    expect(build()).toEqual([]);
    expect(claims).toEqual(
      new Set([
        reverseActionSetKey("run-1", 1),
        reverseActionSetKey("run-1", 2),
      ]),
    );
  });

  it("claims before the first await so concurrent stop causes save one row", async () => {
    const claims = new Set<string>();
    const persist = vi.fn(async () => {
      await Promise.resolve();
    });
    const queue = vi.fn(async () => true);
    const key = reverseActionSetKey("run-1", 1);

    const outcomes = await Promise.all([
      persistReverseActionSetOnce(key, claims, recording(), persist, queue),
      persistReverseActionSetOnce(key, claims, recording(), persist, queue),
      persistReverseActionSetOnce(key, claims, recording(), persist, queue),
    ]);

    expect(outcomes.sort()).toEqual(["already_claimed", "already_claimed", "saved"]);
    expect(persist).toHaveBeenCalledTimes(1);
    expect(queue).not.toHaveBeenCalled();
  });

  it("keeps a durable queued set claimed and releases a totally lost attempt", async () => {
    const key = reverseActionSetKey("run-1", 1);
    const persist = vi.fn(async () => {
      throw new Error("offline");
    });
    const durableClaims = new Set<string>();
    await expect(
      persistReverseActionSetOnce(key, durableClaims, recording(), persist, async () => true),
    ).resolves.toBe("queued");
    await expect(
      persistReverseActionSetOnce(key, durableClaims, recording(), persist, async () => true),
    ).resolves.toBe("already_claimed");

    const lostClaims = new Set<string>();
    await expect(
      persistReverseActionSetOnce(key, lostClaims, recording(), persist, async () => false),
    ).resolves.toBe("lost");
    expect(lostClaims.has(key)).toBe(false);
  });
});
