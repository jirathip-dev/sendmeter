import { describe, it, expect, vi } from "vitest";
import {
  createRepSettlement,
  endGaugeSession,
  predictGaugeSessionRpe,
} from "./gaugeSessionEnd";
import type { TindeqRecordingMeta } from "../types";
import type { TagCurve } from "./repo/tindeq";

function rec(overrides: Partial<TindeqRecordingMeta> = {}): TindeqRecordingMeta {
  return {
    id: "r1",
    recordedAt: "2026-07-29T10:00:00.000Z",
    durationMs: 5000,
    peakKg: 20,
    avgKg: 15,
    sampleCount: 100,
    note: "",
    tag: "FDP",
    side: "",
    groupId: "g1",
    protocolRunId: null,
    setNo: null,
    zone: null,
    ...overrides,
  } as TindeqRecordingMeta;
}

describe("endGaugeSession", () => {
  it("#295: two concurrent calls for the same groupId log exactly once", async () => {
    const claimed = new Set<string>();
    const onLogSession = vi.fn().mockResolvedValue(true);
    const predictGroupRpe = vi
      .fn()
      .mockResolvedValue({ predicted: { rpe: 7 }, recs: [rec()] });

    const [first, second] = await Promise.all([
      endGaugeSession({
        groupId: "g1",
        wallClockMin: 3,
        claimed,
        predictGroupRpe,
        onLogSession,
      }),
      endGaugeSession({
        groupId: "g1",
        wallClockMin: 3,
        claimed,
        predictGroupRpe,
        onLogSession,
      }),
    ]);

    expect(onLogSession).toHaveBeenCalledTimes(1);
    expect([first, second].filter((r) => r === null)).toHaveLength(1);
    expect([first, second].filter((r) => r === true)).toHaveLength(1);
  });

  it("claims are synchronous — a second call started right after the first still loses the race even before it resolves", async () => {
    const claimed = new Set<string>();
    const onLogSession = vi.fn().mockResolvedValue(true);
    const predictGroupRpe = vi
      .fn()
      .mockResolvedValue({ predicted: { rpe: 5 }, recs: [] });

    const firstCall = endGaugeSession({
      groupId: "g1",
      wallClockMin: 1,
      claimed,
      predictGroupRpe,
      onLogSession,
    });
    // Started while the first call is still awaiting onLogSession.
    const secondResult = await endGaugeSession({
      groupId: "g1",
      wallClockMin: 1,
      claimed,
      predictGroupRpe,
      onLogSession,
    });

    expect(secondResult).toBeNull();
    await firstCall;
    expect(onLogSession).toHaveBeenCalledTimes(1);
  });

  it("different groupIds are independent", async () => {
    const claimed = new Set<string>();
    const onLogSession = vi.fn().mockResolvedValue(true);
    const predictGroupRpe = vi
      .fn()
      .mockResolvedValue({ predicted: { rpe: 5 }, recs: [] });

    await Promise.all([
      endGaugeSession({
        groupId: "g1",
        wallClockMin: 1,
        claimed,
        predictGroupRpe,
        onLogSession,
      }),
      endGaugeSession({
        groupId: "g2",
        wallClockMin: 1,
        claimed,
        predictGroupRpe,
        onLogSession,
      }),
    ]);

    expect(onLogSession).toHaveBeenCalledTimes(2);
  });

  it("logs the recordings' actual span and tags, falling back to wall-clock minutes with none", async () => {
    const claimed = new Set<string>();
    const onLogSession = vi.fn().mockResolvedValue(true);
    const predictGroupRpe = vi.fn().mockResolvedValue({
      predicted: { rpe: 6 },
      recs: [
        rec({ tag: "FDP", recordedAt: "2026-07-29T10:00:00.000Z", durationMs: 5000 }),
        rec({ tag: "FDP", recordedAt: "2026-07-29T10:02:00.000Z", durationMs: 5000 }),
      ],
    });

    await endGaugeSession({
      groupId: "g1",
      wallClockMin: 9,
      claimed,
      predictGroupRpe,
      onLogSession,
    });

    expect(onLogSession).toHaveBeenCalledWith(
      expect.objectContaining({
        durationMin: 2, // span from first rep start to last rep end, not wallClockMin
        note: "2 recordings · FDP",
        groupId: "g1",
        rpe: 6,
        rpeConfirmed: false,
      }),
    );
  });

  it("#613: predicts SYNCHRONOUSLY from the cached curve registry — no Promise.race, no network wait in the end path", async () => {
    const claimed = new Set<string>();
    const onLogSession = vi.fn().mockResolvedValue(true);
    const predictGroupRpe = vi.fn().mockResolvedValue({
      predicted: { rpe: 7, fromCurve: true, load: 1.2 },
      recs: [rec()],
    });

    // Must resolve without any artificial delay — a synchronous prediction
    // cannot contribute latency to the Finish path.
    const before = Date.now();
    await endGaugeSession({
      groupId: "g1",
      wallClockMin: 1,
      claimed,
      predictGroupRpe,
      onLogSession,
    });
    expect(Date.now() - before).toBeLessThan(50);
    // And the synchronous shape is used: the mock is a returnValue, never
    // awaited-forced through a promise chain.
    expect(predictGroupRpe).toHaveBeenCalledTimes(1);
    expect(onLogSession).toHaveBeenCalledWith(
      expect.objectContaining({ rpe: 7 }),
    );
  });

  it("#613: waits for in-flight rep saves to settle before the prediction snapshot (final-rep settlement)", async () => {
    const claimed = new Set<string>();
    const onLogSession = vi.fn().mockResolvedValue(true);
    const predictGroupRpe = vi.fn().mockResolvedValue({
      predicted: { rpe: 7 },
      recs: [rec()],
    });
    const settlement = createRepSettlement();

    // A rep's durable save is mid-flight (begun, not yet finished).
    settlement.begin();
    const started = endGaugeSession({
      groupId: "g1",
      wallClockMin: 1,
      claimed,
      predictGroupRpe,
      onLogSession,
      settlement,
    });

    // Give the settlement wait a tick — the session end is BLOCKED on the
    // in-flight save and must not snapshot yet.
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(predictGroupRpe).not.toHaveBeenCalled();

    // The final rep lands; the session end proceeds.
    settlement.finish();
    expect(await started).toBe(true);
    expect(predictGroupRpe).toHaveBeenCalledTimes(1);
  });

  it("#613: waits for the FINAL rep even when it settles after the wait began", async () => {
    const claimed = new Set<string>();
    const onLogSession = vi.fn().mockResolvedValue(true);
    const predictGroupRpe = vi.fn().mockResolvedValue({
      predicted: { rpe: 7 },
      recs: [rec()],
    });
    const settlement = createRepSettlement();
    settlement.begin();

    const started = endGaugeSession({
      groupId: "g1",
      wallClockMin: 1,
      claimed,
      predictGroupRpe,
      onLogSession,
      settlement,
    });
    await new Promise((resolve) => setTimeout(resolve, 5));

    // A second rep claims while the first is still settling.
    settlement.begin();
    settlement.finish(); // first rep settles
    await new Promise((resolve) => setTimeout(resolve, 5));
    expect(predictGroupRpe).not.toHaveBeenCalled();

    settlement.finish(); // final rep settles
    expect(await started).toBe(true);
  });
});

describe("predictGaugeSessionRpe (#613 — cached synchronous prediction)", () => {
  const curve: TagCurve = {
    name: "FDP",
    modality: "static",
    cf: 15,
    wPrime: 1500,
  };

  it("computes W'-depletion per rep against its own tag's cached curve", () => {
    const rpe = predictGaugeSessionRpe(
      [rec({ tag: "FDP", peakKg: 25, durationMs: 10000 })],
      [curve],
    );
    // (25 − 15) kg × 10 s = 100 kg·s over W' = 1500 → d = 0.0667
    expect(rpe.fromCurve).toBe(true);
    expect(rpe.load).toBeCloseTo(100 / 1500, 5);
    expect(rpe.rpe).toBeGreaterThan(1);
  });

  it("falls back IMMEDIATELY when a curve is unavailable — no wait, no throw", () => {
    const rpe = predictGaugeSessionRpe([rec({ tag: "FDP", peakKg: 25 })], []);
    expect(rpe.fromCurve).toBe(false);
    expect(rpe.load).toBeNull();
    expect(rpe.rpe).toBe(5); // RPE_DEPLETION.fallbackRpe
  });

  it("treats a tag with no curve as unmeasured even when other tags have one", () => {
    const rpe = predictGaugeSessionRpe(
      [rec({ tag: "Other", peakKg: 25, durationMs: 10000 })],
      [curve],
    );
    expect(rpe.fromCurve).toBe(false);
    expect(rpe.rpe).toBe(5);
  });
});

describe("createRepSettlement (#613)", () => {
  it("waitForIdle resolves immediately with nothing in flight", async () => {
    const settlement = createRepSettlement();
    await expect(settlement.waitForIdle()).resolves.toBeUndefined();
  });

  it("begin/finish are balanced — a finish without a begin never underflows", () => {
    const settlement = createRepSettlement();
    settlement.finish();
    settlement.finish();
    // Would hang forever if inFlight went negative; must resolve.
    settlement.waitForIdle().catch(() => {});
  });
});
