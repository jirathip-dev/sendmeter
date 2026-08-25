/// Tool-handler tests: each of the six tools driven against a canned
/// DataStore (no network). Covers argument validation, result shape, and
/// the aggregation/derivation logic (peaks, weekly trend, recovery signal).

import { describe, expect, it } from "vitest";
import type {
  DataStore,
  HealthMetricsRow,
  PhasePeriodRow,
  RecordingRow,
  SampleRow,
  SessionRow,
  WorkoutRow,
} from "../src/transport.js";
import {
  analyzeTrainingLoad,
  getAcwr,
  getHealthMetrics,
  getReadiness,
  getSessions,
  getTindeq,
  topPeaks,
} from "../src/queries.js";

function day(daysBack: number): string {
  const d = new Date();
  d.setDate(d.getDate() - daysBack);
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  return `${d.getFullYear()}-${m}-${dd}`;
}

const HEALTH: HealthMetricsRow[] = [
  { date: day(1), readiness: 72, zone: "maintain", computed_at: null, hrv_sdnn_ms: 65.2, resting_hr: 52, sleep_hours: 7.2, sleep_deep_hours: 1.2, sleep_rem_hours: 1.6, body_mass_kg: 68.1, resp_rate_bpm: 14.5 },
  { date: day(0), readiness: 38, zone: "recover", computed_at: null, hrv_sdnn_ms: 55, resting_hr: 55, sleep_hours: 5.1, sleep_deep_hours: 0.8, sleep_rem_hours: 1.0, body_mass_kg: 68.3, resp_rate_bpm: 15.1 },
];

const SESSIONS: SessionRow[] = [
  { id: "s1", date: day(1), type: "gym", type_label: "Gym Session", duration_min: 90, rpe: 6.5, rpe_confirmed: true, load: 585, note: "", phase: "strength", group_id: null, workout_source: null },
  { id: "s2", date: day(1), type: "tindeq", type_label: "Tindeq", duration_min: 12, rpe: 7, rpe_confirmed: true, load: 84, note: "", phase: "strength", group_id: "grp-1", workout_source: null },
  { id: "s3", date: day(0), type: "board", type_label: "Board Climbing", duration_min: 60, rpe: 7.5, rpe_confirmed: true, load: 450, note: "hard set", phase: "strength", group_id: null, workout_source: null },
];

const PHASES: PhasePeriodRow[] = [
  { id: "p1", phase: "capacity", started_on: day(37), ended_on: day(10) },
  { id: "p2", phase: "strength", started_on: day(9), ended_on: null },
];

const WORKOUTS: WorkoutRow[] = [
  { session_id: "s3", started_at: `${day(0)}T18:00:00.000Z`, ended_at: `${day(0)}T19:00:00.000Z`, attempts_detected: 10, attempts_confirmed: 8, source: "watch" },
];

const RECORDINGS: RecordingRow[] = [
  { id: "r1", recorded_at: `${day(3)}T17:00:00.000Z`, duration_ms: 7000, peak_kg: 40, avg_kg: 38.6, sample_count: 71, note: "", tag: "Half crimp", side: "left", group_id: "grp-1", zone: "strength", source: "dynamometer" },
  { id: "r2", recorded_at: `${day(3)}T17:03:00.000Z`, duration_ms: 7000, peak_kg: 42.5, avg_kg: 41.1, sample_count: 71, note: "", tag: "Half crimp", side: "right", group_id: "grp-1", zone: "strength", source: "dynamometer" },
];

function holdSamples(peak: number): [number, number][] {
  const out: [number, number][] = [];
  for (let t = 0; t <= 7000; t += 1000) {
    out.push([t, Math.round((peak * Math.min(t / 3000, 1)) * 100) / 100]);
  }
  return out;
}

const SAMPLES: SampleRow[] = [
  { id: "r1", samples: holdSamples(40) },
  { id: "r2", samples: holdSamples(42.5) },
];

class MockStore implements DataStore {
  healthRows = HEALTH;
  sessionRows = SESSIONS;
  phaseRows = PHASES;
  workoutRows = WORKOUTS;
  recordingRows = RECORDINGS;
  sampleRows = SAMPLES;
  calls: string[] = [];

  async healthMetrics(from: string, to: string) {
    this.calls.push(`healthMetrics(${from},${to})`);
    return this.healthRows.filter((r) => r.date >= from && r.date <= to);
  }
  async sessions(from: string, to: string) {
    this.calls.push(`sessions(${from},${to})`);
    return this.sessionRows.filter((r) => r.date >= from && r.date <= to);
  }
  async phasePeriods() {
    this.calls.push("phasePeriods()");
    return this.phaseRows;
  }
  async workouts(from: string, to: string) {
    this.calls.push(`workouts(${from},${to})`);
    return this.workoutRows.filter((w) => w.started_at >= from);
  }
  async recordingsByGroup(groupId: string) {
    this.calls.push(`recordingsByGroup(${groupId})`);
    return this.recordingRows.filter((r) => r.group_id === groupId);
  }
  async recordingsByIds(ids: string[]) {
    this.calls.push(`recordingsByIds(${ids.join(",")})`);
    return this.recordingRows.filter((r) => ids.includes(r.id));
  }
  async recentRecordings(limit: number) {
    this.calls.push(`recentRecordings(${limit})`);
    return this.recordingRows.slice(0, limit);
  }
  async samplesByIds(ids: string[]) {
    this.calls.push(`samplesByIds(${ids.join(",")})`);
    return this.sampleRows.filter((s) => ids.includes(s.id));
  }
}

describe("get_health_metrics", () => {
  it("returns the requested metric columns only", async () => {
    const store = new MockStore();
    const out = await getHealthMetrics({ from: day(1), to: day(0), metric: "hrv" }, store);
    expect(out.metric).toBe("hrv");
    expect(out.days).toBe(2);
    expect(out.series).toEqual([
      { date: day(1), hrv_sdnn_ms: 65.2 },
      { date: day(0), hrv_sdnn_ms: 55 },
    ]);
  });

  it("returns all four metric groups when metric is omitted", async () => {
    const out = await getHealthMetrics({ from: day(1), to: day(0) }, new MockStore());
    expect(Object.keys(out.series[0]!).sort()).toEqual(
      ["body_mass_kg", "date", "hrv_sdnn_ms", "resting_hr", "sleep_deep_hours", "sleep_hours", "sleep_rem_hours"],
    );
  });

  it("rejects invalid or inverted ranges", async () => {
    await expect(getHealthMetrics({ from: "2026-02-31", to: day(0) }, new MockStore())).rejects.toThrow("invalid date");
    await expect(getHealthMetrics({ from: day(0), to: day(1) }, new MockStore())).rejects.toThrow("from");
    await expect(getHealthMetrics({ from: "garbage", to: day(0) }, new MockStore())).rejects.toThrow("invalid date");
  });
});

describe("get_sessions", () => {
  it("aggregates per day and totals", async () => {
    const out = await getSessions({ from: day(2), to: day(0) }, new MockStore());
    expect(out.session_count).toBe(3);
    expect(out.total_duration_min).toBe(162);
    expect(out.total_load).toBe(1119);
    expect(out.days).toHaveLength(2);
    expect(out.days[0]!.types).toEqual(["Gym Session", "Tindeq"]);
  });

  it("filters by discipline", async () => {
    const out = await getSessions({ from: day(2), to: day(0), discipline: "gym" }, new MockStore());
    expect(out.session_count).toBe(1);
    expect(out.days[0]!.types).toEqual(["Gym Session"]);
  });

  it("includes watch workout attempts", async () => {
    const out = await getSessions({ from: day(2), to: day(0) }, new MockStore());
    expect(out.attempts).toEqual({ workout_count: 1, attempts_confirmed: 8, attempts_detected: 10 });
    expect(out.workouts[0]!.source).toBe("watch");
  });
});

describe("get_readiness", () => {
  it("returns the series and summary", async () => {
    const out = await getReadiness({ days: 14 }, new MockStore());
    expect(out.series.map((s) => s.readiness)).toEqual([72, 38]);
    expect(out.latest).toEqual({ date: day(0), readiness: 38 });
    expect(out.summary).toEqual({
      avg_readiness: 55,
      min_readiness: 38,
      max_readiness: 72,
      low_readiness_days: 1, // 38 < 40
    });
  });

  it("clamps the window to available rows without inventing data", async () => {
    const out = await getReadiness({ days: 365 }, new MockStore());
    expect(out.series).toHaveLength(2);
  });
});

describe("get_acwr", () => {
  it("reports the stored-load ratio and the open phase", async () => {
    const store = new MockStore();
    const out = await getAcwr({ days: 90 }, store);
    expect(out.as_of).toBe(day(0));
    // acute window is the last 7 days: both day(1) sessions (585+84) + day(0) (450)
    expect(out.acute_7d_load).toBe(1119);
    expect(out.phase).toBe("strength");
    expect(out.phase_started_on).toBe(day(9));
    expect(typeof out.acwr).toBe("number");
    expect(out.status).toMatch(/^(No data|Under-training|Low|Optimal|Caution|Danger)$/);
    expect(store.calls).toContain("phasePeriods()");
  });

  it("always fetches the full 90-day EWMA window, regardless of days (#644 F3)", async () => {
    const store = new MockStore();
    await getAcwr({ days: 28 }, store);
    // The fetch must cover the full lookback even when the caller asks for a
    // shorter display window.
    const sessionsCall = store.calls.find((c) => c.startsWith("sessions("))!;
    expect(sessionsCall).toContain(`sessions(${day(89)},`);
  });
});

describe("analyze_training_load fetch window (#644 review F4)", () => {
  it("fetches enough history for the requested weeks (weeks >= 13)", async () => {
    const store = new MockStore();
    await analyzeTrainingLoad({ weeks: 16, days: 90 }, store);
    // 16 weeks × 7 days = 112 days of history — the fetch must cover it, or
    // the oldest buckets are fabricated zero-load weeks.
    const sessionsCall = store.calls.find((c) => c.startsWith("sessions("))!;
    expect(sessionsCall).toContain(`sessions(${day(111)},`);
  });

  it("does not fabricate zero-load weeks or flip the trend for weeks >= 13", async () => {
    // Dead-constant 700/day load for 200 days: every weekly bucket is 4900
    // and the trend is flat at ANY weeks value.
    const rows: { date: string; load: number }[] = [];
    for (let i = 0; i < 200; i++) rows.push({ date: day(i), load: 700 });
    const store = new MockStore();
    store.sessionRows = rows as never;
    for (const weeks of [4, 13, 16]) {
      const out = await analyzeTrainingLoad({ weeks, days: 90 }, store);
      const totals = out.weekly_load.map((w) => w.total_load);
      expect(totals.length, `weeks=${weeks}`).toBe(weeks);
      expect(totals.every((t) => t === 4900), `weeks=${weeks}: ${JSON.stringify(totals)}`).toBe(true);
      expect(out.load_trend, `weeks=${weeks}`).toBe("flat");
    }
  });
});

describe("get_tindeq", () => {
  it("returns a single recording with derived peaks", async () => {
    const out = await getTindeq({ recording_id: "r1", limit: 10 }, new MockStore());
    expect(out.scope).toEqual({ kind: "recording", id: "r1" });
    expect(out.recordings).toHaveLength(1);
    expect(out.summary.best_peak_kg).toBe(40);
    // mock curve peaks at t=3000 (plateau start; plateau counted once)
    expect(out.peaks[0]!.peaks[0]!.kg).toBe(40);
    expect(out.peaks[0]!.peaks[0]!.t_ms).toBe(3000);
  });

  it("groups by session_id", async () => {
    const out = await getTindeq({ session_id: "grp-1", limit: 10 }, new MockStore());
    expect(out.scope).toEqual({ kind: "session", id: "grp-1" });
    expect(out.recordings).toHaveLength(2);
    expect(out.summary.best_peak_kg).toBe(42.5);
    expect(out.peaks).toHaveLength(2);
  });

  it("returns recent recordings without sample work when nothing is requested", async () => {
    const store = new MockStore();
    const out = await getTindeq({ limit: 1 }, store);
    expect(out.scope.kind).toBe("recent");
    expect(out.recordings).toHaveLength(1);
    expect(out.peaks).toEqual([]);
    expect(store.calls).not.toContain("samplesByIds(r1)");
  });

  it("keeps the summary honest when no recording matches", async () => {
    const out = await getTindeq({ recording_id: "missing", limit: 10 }, new MockStore());
    expect(out.recordings).toHaveLength(0);
    expect(out.summary.best_peak_kg).toBeNull();
    expect(out.peaks).toEqual([]);
  });
});

describe("topPeaks", () => {
  const samples: [number, number][] = [
    [0, 10], [100, 20], [200, 30], [300, 20], [400, 50], [500, 40], [600, 60], [700, 60], [800, 45],
  ];
  it("finds local maxima best-first", () => {
    expect(topPeaks(samples, 3)).toEqual([
      { t_ms: 600, kg: 60 },
      { t_ms: 400, kg: 50 },
      { t_ms: 200, kg: 30 },
    ]);
  });
  it("counts a plateau once and respects the cap", () => {
    expect(topPeaks(samples, 1)).toEqual([{ t_ms: 600, kg: 60 }]);
  });
  it("returns nothing for a flat or empty series", () => {
    expect(topPeaks([], 5)).toEqual([]);
    expect(topPeaks([[0, 5], [100, 5], [200, 5]], 5)).toEqual([]);
  });

  it("keeps a second genuine peak of identical magnitude (#644 F14)", () => {
    // Two separate reps landing on the same rounded kg must BOTH be reported.
    expect(topPeaks([[0, 1], [100, 5], [200, 1], [300, 5], [400, 1]], 5)).toEqual([
      { t_ms: 100, kg: 5 },
      { t_ms: 300, kg: 5 },
    ]);
  });

  it("keeps a peak at the final sample (#644 F14)", () => {
    expect(topPeaks([[0, 1], [100, 3], [200, 9]], 5)).toEqual([{ t_ms: 200, kg: 9 }]);
    expect(topPeaks([[0, 9], [100, 3], [200, 1]], 5)).toEqual([{ t_ms: 0, kg: 9 }]);
  });

  it("keeps separate same-magnitude reps, merging only adjacent plateau samples", () => {
    // Three genuine reps all landing on the same rounded kg (100/300/500) are
    // ALL kept — the old dedupe compared kg to the previous peak and dropped
    // every one after the first.
    expect(topPeaks([[0, 1], [100, 5], [200, 1], [300, 5], [400, 1], [500, 5], [600, 1]], 5)).toEqual([
      { t_ms: 100, kg: 5 },
      { t_ms: 300, kg: 5 },
      { t_ms: 500, kg: 5 },
    ]);
  });
});

describe("analyze_training_load", () => {
  it("produces weekly buckets, trend, ACWR, recovery signal and notes", async () => {
    const out = await analyzeTrainingLoad({ weeks: 4, days: 90 }, new MockStore());
    expect(out.weeks).toBe(4);
    expect(out.weekly_load).toHaveLength(4);
    // oldest-first, like the web's computeWeeklyLoads — the "Now" bucket is last
    expect(out.weekly_load[3]!.label).toBe("Now");
    // week 0 spans daysAgo(6)..today: all three mock sessions are inside
    expect(out.weekly_load[3]!.total_load).toBe(1119);
    expect(out.weekly_load[3]!.session_count).toBe(3);
    expect(out.acwr.status).toBeTruthy();
    expect(out.recovery.low_readiness_days).toBe(1);
    expect(out.phase).toBe("strength");
    const noteText = out.notes.join("\n");
    // one low-readiness day is not (yet) a 3-day deficit — no deficit note
    expect(noteText).not.toContain("below the recovery threshold");
    expect(noteText).toContain("ACWR is in the danger zone");
  });

  it("reports insufficient data when the current week has no sessions", async () => {
    const store = new MockStore();
    store.sessionRows = [];
    const out = await analyzeTrainingLoad({ weeks: 4, days: 90 }, store);
    expect(out.load_trend).toBe("insufficient_data");
    expect(out.notes).toContain("No training sessions logged this week.");
    expect(out.acwr.acwr).toBeNull();
  });
});
