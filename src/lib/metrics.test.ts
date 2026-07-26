import { describe, it, expect } from "vitest";
import {
  ACUTE_SPAN_DAYS,
  ACWR_TRACK_GRADIENT,
  CHRONIC_SPAN_DAYS,
  ewmaLoadState,
  getACWRStatus,
  computeAcwr,
  computeWeeklyLoads,
  computeTindeqStats,
  currentPeriodStart,
  ewma,
  phaseAcwrFit,
  phaseStartFromHistory,
  suggestPhaseStepBack,
} from "./metrics";
import { today, daysAgo } from "./dates";
import type { HealthMetric, PhasePeriod, Session, TindeqRecordingMeta } from "../types";

function readiness(date: string, value: number | null): Pick<HealthMetric, "date" | "readiness"> {
  return { date, readiness: value };
}

function session(date: string, load: number): Session {
  return {
    id: `s-${date}-${load}`,
    date,
    type: "board",
    typeLabel: "Board",
    duration: 60,
    rpe: 5,
    rpeConfirmed: true,
    load,
    note: "",
    phase: "capacity",
    groupId: null,
    workoutSource: null,
  };
}

function period(
  phase: PhasePeriod["phase"],
  startedOn: string,
  endedOn: string | null,
): Pick<PhasePeriod, "phase" | "startedOn" | "endedOn"> {
  return { phase, startedOn, endedOn };
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
    zone: null,
    protocolRunId: null,
    setNo: null,
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

describe("ACWR_TRACK_GRADIENT", () => {
  // Parse "var(--color) NN%" stops out of the linear-gradient string, in
  // declared order.
  function parseStops(gradient: string): { color: string; pct: number }[] {
    const matches = [...gradient.matchAll(/var\(--([\w-]+)\)\s+(\d+(?:\.\d+)?)%/g)];
    return matches.map((m) => ({ color: m[1]!, pct: Number(m[2]) }));
  }

  it("has no two consecutive stops at the same position (issue #213: hard stops flatten the blend)", () => {
    const stops = parseStops(ACWR_TRACK_GRADIENT);
    for (let i = 0; i < stops.length - 1; i++) {
      expect(stops[i]!.pct).not.toBe(stops[i + 1]!.pct);
    }
  });

  it("blends symmetrically so each true threshold (40/65/75) sits at the midpoint of its blend", () => {
    const stops = parseStops(ACWR_TRACK_GRADIENT);
    const pcts = stops.map((s) => s.pct);
    // info -> success blend brackets the 0.8 threshold (40%)
    const infoEnd = pcts[1]!;
    const successStart = pcts[2]!;
    expect((infoEnd + successStart) / 2).toBe(40);
    // success -> warning blend brackets the 1.3 threshold (65%)
    const successEnd = pcts[3]!;
    const warningStart = pcts[4]!;
    expect((successEnd + warningStart) / 2).toBe(65);
    // warning -> danger blend brackets the 1.5 threshold (75%)
    const warningEnd = pcts[4]!;
    const dangerStart = pcts[5]!;
    expect((warningEnd + dangerStart) / 2).toBe(75);
  });

  it("stop colors appear in risk order: info -> success -> warning -> danger", () => {
    const stops = parseStops(ACWR_TRACK_GRADIENT);
    const order: string[] = [];
    for (const s of stops) {
      if (order[order.length - 1] !== s.color) order.push(s.color);
    }
    expect(order).toEqual(["info", "success", "warning", "danger"]);
  });
});

describe("ewma", () => {
  it("is the identity for a constant series", () => {
    expect(ewma([5, 5, 5, 5], 7)).toEqual([5, 5, 5, 5]);
  });

  it("converges toward a step and never overshoots", () => {
    const out = ewma([0, 10, 10, 10, 10, 10, 10, 10, 10, 10], 3) as number[];
    for (let i = 1; i < out.length; i++) {
      expect(out[i]!).toBeGreaterThan(out[i - 1]!); // monotone rise
      expect(out[i]!).toBeLessThanOrEqual(10);
    }
    expect(out[out.length - 1]!).toBeCloseTo(10, 1);
  });

  it("carries the EMA through interior nulls unchanged", () => {
    const out = ewma([4, null, null, 4], 7);
    expect(out).toEqual([4, 4, 4, 4]);
    const stepped = ewma([0, 10, null, 10], 3) as number[];
    expect(stepped[2]).toBe(stepped[1]); // null day = no update
  });

  it("leaves leading nulls null and seeds at the first value", () => {
    const out = ewma([null, null, 8, 8], 7);
    expect(out[0]).toBeNull();
    expect(out[1]).toBeNull();
    expect(out[2]).toBe(8);
    expect(out[3]).toBe(8);
  });

  it("span 1 tracks the input exactly (lambda = 1)", () => {
    expect(ewma([1, 9, 2, 7], 1)).toEqual([1, 9, 2, 7]);
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

  it("watch/web ACWR parity (issue #189): pins the ratio for a fixed 90-day fixture", () => {
    // Same deterministic (integer-arithmetic, no transcendental functions —
    // reproducible bit-for-bit) 90-day load series as
    // ios/App/SendLogWatchCore/Tests/SendLogWatchCoreTests/ACWRTests.swift's
    // testMatchesWebFixtureVector, fed
    // in oldest → newest (dailyLoads[0] on daysAgo(89), ..., dailyLoads[89]
    // on today()). The watch used to compute ACWR with a 28-day series
    // seeded at the raw first-day value; the web used a 90-day,
    // mean-seeded series — same underlying data, two different numbers.
    // ewmaAcwr/dailyLoadSeries on the watch now mirror ewmaAcwr here
    // exactly (see ACWR.swift's KEEP-IN-SYNC comment); this test and its
    // Swift twin pin both sides to the same expected ratio so a future
    // change to either implementation that silently re-diverges the math
    // fails loudly instead of quietly drifting again.
    const dailyLoads = Array.from({ length: 90 }, (_, i) => (i * 13 + 7) % 47);
    const sessions = dailyLoads.map((load, i) => session(daysAgo(89 - i), load));
    expect(computeAcwr(sessions).acwr).toBeCloseTo(1.1151915681290694, 9);
  });
});

describe("ewmaLoadState", () => {
  it("is null when there's no load in the lookback window", () => {
    expect(ewmaLoadState([])).toBeNull();
    expect(ewmaLoadState([session(daysAgo(200), 500)])).toBeNull();
  });

  it("its acute/chronic pair IS computeAcwr's ratio — not a second opinion", () => {
    const sessions = Array.from({ length: 40 }, (_, i) => session(daysAgo(i), 90 + i * 7));
    const state = ewmaLoadState(sessions)!;
    expect(state.acute / state.chronic).toBe(computeAcwr(sessions).acwr);
  });

  it("exposes the spans the ratio is built from", () => {
    expect(ACUTE_SPAN_DAYS).toBe(7);
    expect(CHRONIC_SPAN_DAYS).toBe(28);
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

describe("phaseAcwrFit", () => {
  const capacity = { acwrLow: 0.9, acwrHigh: 1.1 }; // wider, high-volume base
  const power = { acwrLow: 0.8, acwrHigh: 1.0 }; // aims lower/hotter

  it("is null without an ACWR or a phase", () => {
    expect(phaseAcwrFit(null, capacity)).toBeNull();
    expect(phaseAcwrFit(1.0, undefined)).toBeNull();
  });

  it("classifies below / on / above the phase's target band (inclusive edges)", () => {
    expect(phaseAcwrFit(0.85, capacity)).toBe("below");
    expect(phaseAcwrFit(0.9, capacity)).toBe("on");
    expect(phaseAcwrFit(1.0, capacity)).toBe("on");
    expect(phaseAcwrFit(1.1, capacity)).toBe("on");
    expect(phaseAcwrFit(1.2, capacity)).toBe("above");
  });

  it("the same ratio reads differently against different phases", () => {
    // 1.05 is on-target in a capacity block but above a power block's ceiling
    expect(phaseAcwrFit(1.05, capacity)).toBe("on");
    expect(phaseAcwrFit(1.05, power)).toBe("above");
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

describe("currentPeriodStart", () => {
  const fallback = "2026-07-19";

  it("falls back to phaseStartDate when phasePeriods is empty", () => {
    // e.g. first mount, before runFetch resolves
    expect(currentPeriodStart([], "capacity", fallback)).toBe(fallback);
  });

  it("returns the open period's startedOn when its phase matches currentPhase", () => {
    const periods = [
      period("capacity", "2026-07-05", null), // open, matches
    ];
    expect(currentPeriodStart(periods, "capacity", fallback)).toBe("2026-07-05");
  });

  it("issue #170 regression: ignores a stale open period from a different phase", () => {
    // Simulates the transient window right after setPhase optimistically
    // flips currentPhase to "strength" before repo.switchPhase resolves and
    // refreshes phasePeriods — the still-open period here is Capacity's.
    const periods = [
      period("capacity", "2026-07-11", null), // stale open period, wrong phase
    ];
    expect(currentPeriodStart(periods, "strength", fallback)).toBe(fallback);
  });

  it("ignores an ended period even if its phase matches currentPhase", () => {
    const periods = [
      period("capacity", "2026-07-01", "2026-07-10"), // ended, matches phase
      period("strength", "2026-07-11", null), // open, different phase
    ];
    expect(currentPeriodStart(periods, "capacity", fallback)).toBe(fallback);
  });
});

describe("phaseStartFromHistory", () => {
  const fallback = "2026-07-19";

  it("falls back when no current-phase session exists yet", () => {
    expect(phaseStartFromHistory([], "capacity", fallback)).toBe(fallback);
    // newest session is a different phase → streak is empty → fallback
    expect(
      phaseStartFromHistory([{ date: "2026-07-18", phase: "strength" }], "capacity", fallback),
    ).toBe(fallback);
  });

  it("returns the earliest session of the current phase's streak", () => {
    const sessions = [
      { date: "2026-07-18", phase: "capacity" as const },
      { date: "2026-07-15", phase: "capacity" as const },
      { date: "2026-07-10", phase: "capacity" as const }, // earliest in streak
    ];
    expect(phaseStartFromHistory(sessions, "capacity", fallback)).toBe("2026-07-10");
  });

  it("survives a brief toggle to another phase that logged nothing", () => {
    // Capacity for days, a Strength period was opened + closed with no session,
    // now back on Capacity. All sessions are capacity → count from the first.
    const sessions = [
      { date: "2026-07-19", phase: "capacity" as const }, // after returning
      { date: "2026-07-12", phase: "capacity" as const },
      { date: "2026-07-02", phase: "capacity" as const }, // real start
    ];
    // fallback (today's fresh period) would wrongly give Day 1
    expect(phaseStartFromHistory(sessions, "capacity", fallback)).toBe("2026-07-02");
  });

  it("resets when a real different-phase block interrupts the streak", () => {
    const sessions = [
      { date: "2026-07-18", phase: "capacity" as const },
      { date: "2026-07-16", phase: "capacity" as const }, // new capacity block start
      { date: "2026-07-14", phase: "strength" as const }, // breaks the streak
      { date: "2026-07-05", phase: "capacity" as const }, // older — not counted
    ];
    expect(phaseStartFromHistory(sessions, "capacity", fallback)).toBe("2026-07-16");
  });
});

describe("suggestPhaseStepBack", () => {
  it("suggests stepping back at exactly the N-day threshold in a power phase", () => {
    const history = [
      readiness(today(), 35),
      readiness(daysAgo(1), 30),
      readiness(daysAgo(2), 38),
      readiness(daysAgo(3), 90), // outside the streak — must not be counted
    ];
    const result = suggestPhaseStepBack(history, "power");
    expect(result.streakDays).toBe(3);
    expect(result.suggested).toBe(true);
  });

  it("does not suggest one day short of the threshold", () => {
    const history = [readiness(today(), 35), readiness(daysAgo(1), 30)];
    const result = suggestPhaseStepBack(history, "strength");
    expect(result.streakDays).toBe(2);
    expect(result.suggested).toBe(false);
  });

  it("breaks the streak on a missing day (sparse history is conservative)", () => {
    const history = [
      readiness(today(), 35),
      readiness(daysAgo(1), 30),
      // daysAgo(2) missing entirely — no reading, not a good one
      readiness(daysAgo(3), 20),
      readiness(daysAgo(4), 20),
    ];
    const result = suggestPhaseStepBack(history, "power");
    expect(result.streakDays).toBe(2);
    expect(result.suggested).toBe(false);
  });

  it("breaks the streak on a day with a null score (metrics row present but no baseline yet)", () => {
    const history = [
      readiness(today(), 35),
      readiness(daysAgo(1), 30),
      readiness(daysAgo(2), null),
      readiness(daysAgo(3), 20),
    ];
    const result = suggestPhaseStepBack(history, "power");
    expect(result.streakDays).toBe(2);
    expect(result.suggested).toBe(false);
  });

  it("clears once readiness recovers, even with a prior long low streak", () => {
    const history = [
      readiness(today(), 72), // recovered
      readiness(daysAgo(1), 30),
      readiness(daysAgo(2), 30),
      readiness(daysAgo(3), 30),
      readiness(daysAgo(4), 30),
    ];
    const result = suggestPhaseStepBack(history, "power");
    expect(result.streakDays).toBe(0);
    expect(result.suggested).toBe(false);
  });

  it("never suggests when already in the capacity phase", () => {
    const history = [
      readiness(today(), 20),
      readiness(daysAgo(1), 20),
      readiness(daysAgo(2), 20),
      readiness(daysAgo(3), 20),
    ];
    const result = suggestPhaseStepBack(history, "capacity");
    expect(result).toEqual({ suggested: false, streakDays: 0 });
  });

  it("never suggests in the execution (taper/comp) phase", () => {
    const history = [
      readiness(today(), 20),
      readiness(daysAgo(1), 20),
      readiness(daysAgo(2), 20),
    ];
    const result = suggestPhaseStepBack(history, "execution");
    expect(result).toEqual({ suggested: false, streakDays: 0 });
  });

  it("gives no suggestion on empty history", () => {
    expect(suggestPhaseStepBack([], "power")).toEqual({ suggested: false, streakDays: 0 });
  });

  it("keeps suggesting past the threshold (streak grows, not just clamps)", () => {
    const history = [
      readiness(today(), 30),
      readiness(daysAgo(1), 30),
      readiness(daysAgo(2), 30),
      readiness(daysAgo(3), 30),
      readiness(daysAgo(4), 30),
    ];
    const result = suggestPhaseStepBack(history, "strength");
    expect(result.streakDays).toBe(5);
    expect(result.suggested).toBe(true);
  });

  it("treats the low threshold as exclusive at the boundary (40 itself is not low)", () => {
    const history = [
      readiness(today(), 40),
      readiness(daysAgo(1), 30),
      readiness(daysAgo(2), 30),
    ];
    const result = suggestPhaseStepBack(history, "power");
    expect(result.streakDays).toBe(0);
    expect(result.suggested).toBe(false);
  });
});
