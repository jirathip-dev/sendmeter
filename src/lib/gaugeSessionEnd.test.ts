import { describe, it, expect, vi } from "vitest";
import { endGaugeSession } from "./gaugeSessionEnd";
import type { TindeqRecordingMeta } from "../types";

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
    // Started while the first call is still awaiting predictGroupRpe.
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
});
