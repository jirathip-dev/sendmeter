import { describe, it, expect } from "vitest";
import {
  getACWRStatus,
  computeAcwr,
  computeWeeklyLoads,
  computeTindeqStats,
} from "./metrics";
import { today, daysAgo } from "./dates";
import type { Session, TindeqRecordingMeta } from "../types";

function session(date: string, load: number): Session {
  return {
    id: `s-${date}-${load}`,
    date,
    type: "board",
    typeLabel: "Board",
    duration: 60,
    rpe: 5,
    load,
    note: "",
    phase: "capacity",
    groupId: null,
  };
}

function rec(recordedAt: string, peakKg: number): TindeqRecordingMeta {
  return {
    id: recordedAt,
    recordedAt,
    durationMs: 5000,
    peakKg,
    avgKg: peakKg * 0.8,
    sampleCount: 50,
    note: "",
    tag: "FDP",
    side: "",
    groupId: null,
  };
}

describe("getACWRStatus", () => {
  it("buckets the ratio into the documented risk zones (inclusive edges)", () => {
    expect(getACWRStatus(null).label).toBe("No data");
    expect(getACWRStatus(0.5).label).toBe("Under-training");
    expect(getACWRStatus(0.7).label).toBe("Low");
    expect(getACWRStatus(0.8).label).toBe("Low");
    expect(getACWRStatus(0.85).label).toBe("Optimal");
    expect(getACWRStatus(1.3).label).toBe("Optimal");
    expect(getACWRStatus(1.4).label).toBe("Caution");
    expect(getACWRStatus(1.5).label).toBe("Caution");
    expect(getACWRStatus(1.6).label).toBe("Danger");
  });
});

describe("computeAcwr", () => {
  it("is empty/null with no sessions", () => {
    const r = computeAcwr([]);
    expect(r.acute).toBe(0);
    expect(r.chronic).toBe(0);
    expect(r.acwr).toBeNull();
  });

  it("acute = 7-day sum, chronic = 28-day sum / 4", () => {
    const r = computeAcwr([
      session(today(), 100),
      session(daysAgo(3), 100), // inside 7d
      session(daysAgo(20), 400), // inside 28d, outside 7d
    ]);
    expect(r.acute).toBe(200);
    expect(r.chronic).toBe((200 + 400) / 4); // 150
    expect(r.acwr).not.toBeNull();
    expect(r.acwr!).toBeGreaterThan(0);
  });

  it("ratio ≈ 1 for a steady daily load (EWMA acute and chronic converge)", () => {
    const steady = Array.from({ length: 90 }, (_, i) => session(daysAgo(i), 100));
    expect(computeAcwr(steady).acwr!).toBeCloseTo(1, 1);
  });

  it("ratio is null when there is no load within the 90-day window", () => {
    expect(computeAcwr([session(daysAgo(200), 500)]).acwr).toBeNull();
  });
});

describe("computeWeeklyLoads", () => {
  it("buckets loads into 3w/2w/1w/Now", () => {
    const r = computeWeeklyLoads([
      session(today(), 100),
      session(daysAgo(10), 50), // 1w bucket (7–13d)
    ]);
    expect(r.map((b) => b.label)).toEqual(["3w", "2w", "1w", "Now"]);
    expect(r.find((b) => b.label === "Now")!.total).toBe(100);
    expect(r.find((b) => b.label === "1w")!.total).toBe(50);
    expect(r.find((b) => b.label === "3w")!.total).toBe(0);
  });
});

describe("computeTindeqStats", () => {
  it("needs at least 2 recordings", () => {
    expect(computeTindeqStats([])).toBeNull();
    expect(computeTindeqStats([rec(new Date().toISOString(), 30)])).toBeNull();
  });

  it("reports best/last peaks and the delta vs 30-day average", () => {
    const now = Date.now();
    const iso = (msAgo: number) => new Date(now - msAgo).toISOString();
    const s = computeTindeqStats([
      rec(iso(3 * 86400000), 30), // 3 days ago
      rec(iso(1 * 86400000), 34), // 1 day ago (best)
      rec(iso(0), 32), // now (last)
    ])!;
    expect(s.bestPeak).toBe(34);
    expect(s.lastPeak).toBe(32);
    expect(s.avg30d).toBe(32); // mean of the two earlier within 30d: (30+34)/2
    expect(s.delta).toBe(0); // 32 − 32
  });
});
