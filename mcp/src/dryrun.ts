/// In-memory DataStore for `--dry-run`: synthetic-but-plausible data shaped
/// like the local stack's seed (supabase/seed.sql), so the six tools can be
/// exercised end-to-end — schema parse → handler → JSON result — with no
/// network and no credentials. Never used by the live server path.

import type {
  DataStore,
  HealthMetricsRow,
  PhasePeriodRow,
  RecordingRow,
  SampleRow,
  SessionRow,
  WorkoutRow,
} from "./transport.js";
import { daysAgo, localDayRange } from "./dates.js";

function isoDaysAgo(n: number, hour = 17): string {
  const d = new Date();
  d.setDate(d.getDate() - n);
  d.setHours(hour, 0, 0, 0);
  return d.toISOString();
}

const SESSION_TYPES: [number, string, string, number, number][] = [
  [1, "board", "Board Climbing", 60, 7.5],
  [3, "fingerboard", "Fingerboard", 45, 6],
  [5, "gym", "Gym Session", 90, 6.5],
  [6, "outdoor", "Outdoor / Projecting", 150, 5],
];

const READY_SCORES = [72, 68, 74, 81, 79, 65, 70, 77, 73, 85, 82, 66, 71, 75];

export function dryRunStore(): DataStore {
  const sessions: SessionRow[] = [];
  for (let d = 1; d <= 42; d++) {
    const date = daysAgo(d);
    const dow = new Date(date + "T12:00:00").getDay();
    const t = SESSION_TYPES.find(([w]) => w === dow);
    if (!t) continue;
    const [, type, label, duration, rpe] = t;
    const phase = d <= 9 ? "strength" : "capacity";
    sessions.push({
      id: `session-${d}`,
      date,
      type,
      type_label: label,
      duration_min: duration + (d % 3) * 5,
      rpe,
      rpe_confirmed: true,
      load: (duration + (d % 3) * 5) * rpe,
      note: "",
      phase,
      group_id: null,
      workout_source: null,
    });
  }

  const health: HealthMetricsRow[] = [];
  for (let d = 34; d >= 0; d--) {
    const date = daysAgo(d);
    const score = READY_SCORES[d % READY_SCORES.length]!;
    health.push({
      date,
      readiness: score,
      zone: score < 50 ? "recover" : score >= 75 ? "push" : "maintain",
      computed_at: isoDaysAgo(d, 12),
      hrv_sdnn_ms: Math.round((65 + 8 * Math.sin(d * 1.7)) * 10) / 10,
      resting_hr: Math.round((52 + 2.5 * Math.sin(d * 0.9)) * 10) / 10,
      sleep_hours: Math.round((7.2 + 0.8 * Math.sin(d * 1.3)) * 100) / 100,
      sleep_deep_hours: Math.round((1.2 + 0.3 * Math.sin(d * 0.7)) * 100) / 100,
      sleep_rem_hours: Math.round((1.6 + 0.3 * Math.cos(d * 1.1)) * 100) / 100,
      body_mass_kg: Math.round((68 + 0.4 * Math.sin(d * 0.5)) * 10) / 10,
      resp_rate_bpm: Math.round((14.5 + 0.6 * Math.sin(d)) * 10) / 10,
    });
  }

  const phases: PhasePeriodRow[] = [
    { id: "phase-capacity", phase: "capacity", started_on: daysAgo(37), ended_on: daysAgo(10) },
    { id: "phase-strength", phase: "strength", started_on: daysAgo(9), ended_on: null },
  ];

  const workouts: WorkoutRow[] = [
    {
      session_id: "session-auto",
      started_at: isoDaysAgo(3, 18),
      ended_at: isoDaysAgo(3, 19 + 0.58),
      attempts_detected: 18,
      attempts_confirmed: 16,
      source: "watch",
    },
  ];

  function holdSamples(peak: number): [number, number][] {
    const out: [number, number][] = [];
    for (let t = 0; t <= 7000; t += 100) {
      const kg =
        peak * Math.min(t / 1200, 1) -
        Math.max(t - 1200, 0) * 0.0015 +
        0.5 * Math.sin(t / 180);
      out.push([t, Math.round(kg * 100) / 100]);
    }
    return out;
  }

  const recordings: RecordingRow[] = [
    {
      id: "recording-1",
      recorded_at: isoDaysAgo(3, 17),
      duration_ms: 7000,
      peak_kg: 40,
      avg_kg: 38.6,
      sample_count: 71,
      note: "",
      tag: "Half crimp",
      side: "left",
      group_id: "aaaaaaaa-0000-0000-0000-000000000002",
      zone: "strength",
      source: "dynamometer",
    },
    {
      id: "recording-2",
      recorded_at: isoDaysAgo(3, 17 + 0.05),
      duration_ms: 7000,
      peak_kg: 42.5,
      avg_kg: 41.1,
      sample_count: 71,
      note: "",
      tag: "Half crimp",
      side: "right",
      group_id: "aaaaaaaa-0000-0000-0000-000000000002",
      zone: "strength",
      source: "dynamometer",
    },
  ];
  const samples: SampleRow[] = recordings.map((r) => ({
    id: r.id,
    samples: holdSamples(r.peak_kg!),
  }));

  return {
    async healthMetrics(from, to) {
      return health.filter((h) => h.date >= from && h.date <= to);
    },
    async sessions(from, to) {
      return sessions.filter((s) => s.date >= from && s.date <= to);
    },
    async phasePeriods() {
      return phases;
    },
    async workouts(from, to) {
      const start = localDayRange(from).start;
      const end = localDayRange(to).end;
      return workouts.filter((w) => w.started_at >= start && w.started_at < end);
    },
    async recordingsByGroup(groupId) {
      return recordings.filter((r) => r.group_id === groupId);
    },
    async recordingsByIds(ids) {
      return recordings.filter((r) => ids.includes(r.id));
    },
    async recentRecordings(limit) {
      return recordings.slice(0, limit);
    },
    async samplesByIds(ids) {
      return samples.filter((s) => ids.includes(s.id));
    },
  };
}
