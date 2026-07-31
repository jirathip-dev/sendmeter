import { describe, expect, it } from "vitest";
import {
  analyzeRpeStability,
  driftStats,
  type RpeStabilityRecording,
  type RpeStabilitySession,
} from "./rpeStability";
import type { TindeqSample } from "../types";

function decay(seconds: number, startKg: number, slopeKgS: number): TindeqSample[] {
  const samples: TindeqSample[] = [];
  for (let ms = 0; ms <= seconds * 1000; ms += 100) {
    samples.push({ t: ms, kg: Math.max(0, startKg - slopeKgS * (ms / 1000)) });
  }
  return samples;
}

function recording(
  id: string,
  day: number,
  groupId: string | null,
  startKg: number,
  slopeKgS: number,
): RpeStabilityRecording {
  const samples = decay(120, startKg, slopeKgS);
  return {
    id,
    userId: "u1",
    recordedAt: `2026-01-${String(day).padStart(2, "0")}T12:00:00.000Z`,
    durationMs: 120_000,
    peakKg: startKg,
    avgKg: samples.reduce((sum, sample) => sum + sample.kg, 0) / samples.length,
    tag: "FDP",
    side: "left",
    groupId,
    zone: "endurance",
    samples,
  };
}

function session(id: string, groupId: string): RpeStabilitySession {
  return {
    id,
    userId: "u1",
    groupId,
    type: "tindeq",
    rpe: 5,
    rpeConfirmed: false,
  };
}

describe("driftStats", () => {
  it("reports median, interpolated P90 and material-change rates", () => {
    expect(driftStats([0, 0.2, 0.5, 0.8, 1.4])).toEqual({
      count: 5,
      median: 0.5,
      p90: 1.16,
      overHalfPoint: { count: 2, pct: 40 },
      overOnePoint: { count: 1, pct: 20 },
    });
  });

  it("returns honest empty statistics", () => {
    expect(driftStats([])).toEqual({
      count: 0,
      median: null,
      p90: null,
      overHalfPoint: { count: 0, pct: 0 },
      overOnePoint: { count: 0, pct: 0 },
    });
  });
});

describe("analyzeRpeStability", () => {
  it("uses only the curve available before a session, then measures later refits", () => {
    const report = analyzeRpeStability({
      recordings: [
        recording("seed", 1, null, 55, 0.2),
        recording("g1", 2, "group-1", 48, 0.12),
        recording("g2", 3, "group-2", 62, 0.3),
      ],
      sessions: [session("s1", "group-1"), session("s2", "group-2")],
    });

    expect(report.totalMatchedSessions).toBe(2);
    expect(report.fullyMeasuredAtBaseline).toBe(2);
    expect(report.sessionsWithRelevantRefit).toBe(2);
    expect(report.maximumDrift.count).toBe(2);
    expect(report.sessions.every((item) => item.relevantRefits >= 1)).toBe(true);
  });

  it("separates curve-availability transitions from W-prime refit stability", () => {
    const report = analyzeRpeStability({
      recordings: [
        recording("first", 1, "group-1", 55, 0.2),
        recording("second", 2, "group-2", 52, 0.16),
      ],
      sessions: [session("s1", "group-1"), session("s2", "group-2")],
    });

    expect(report.sessions[0]!.fullyMeasuredAtBaseline).toBe(false);
    expect(report.sessions[1]!.fullyMeasuredAtBaseline).toBe(true);
    expect(report.notFullyMeasuredAtBaseline).toBe(1);
    expect(report.maximumDrift.count).toBe(1);
  });

  it("keeps different users isolated even when group and tag names match", () => {
    const u1 = recording("u1-seed", 1, null, 55, 0.2);
    const u2 = { ...recording("u2-seed", 1, null, 35, 0.1), userId: "u2" };
    const g1 = recording("u1-g", 2, "same-group", 50, 0.15);
    const g2 = { ...recording("u2-g", 2, "same-group", 32, 0.08), userId: "u2" };
    const report = analyzeRpeStability({
      recordings: [u1, u2, g1, g2],
      sessions: [
        session("u1-session", "same-group"),
        { ...session("u2-session", "same-group"), userId: "u2" },
      ],
    });

    expect(report.totalMatchedSessions).toBe(2);
    expect(report.sessions.map((item) => item.sessionId).sort()).toEqual([
      "u1-session",
      "u2-session",
    ]);
  });
});
