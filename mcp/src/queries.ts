/// The six tool implementations. Each handler is a pure function of
/// (validated args, DataStore) — no I/O of its own, so unit tests drive them
/// with a mock store and the only network-capable seam is the store itself
/// (which is itself mockable at the fetch level). Every query is scoped by
/// RLS to the authenticated user; the server holds no other credential.

import type { DataStore, RecordingRow, SessionRow } from "./transport.js";
import {
  acwrStatusLabel,
  computeAcwr,
  computeWeeklyLoads,
  EWMA_LOOKBACK_DAYS,
  type LoadSession,
} from "./load.js";
import { daysAgo, isDateString, today } from "./dates.js";

const LOW_READINESS_THRESHOLD = 40; // mirrors src/lib/metrics.ts

/// Max number of days a `from`/`to` range may span (issue #644 review F15).
/// Beyond this PostgREST's default max_rows (1000) could silently truncate;
/// we reject the range up front instead of returning a partial truth.
const MAX_RANGE_DAYS = 365;

/// The EWMA ratio is defined over a fixed EWMA_LOOKBACK_DAYS (90) daily
/// series, regardless of the caller's `days` display window (issue #644
/// review F3). The session fetch always covers the full lookback so a small
/// `days` can never fabricate zero-load days inside the EWMA.
const ACWR_FETCH_DAYS = EWMA_LOOKBACK_DAYS;

const METRIC_COLUMNS = {
  hrv: ["hrv_sdnn_ms"],
  rhr: ["resting_hr"],
  sleep: ["sleep_hours", "sleep_deep_hours", "sleep_rem_hours"],
  weight: ["body_mass_kg"],
} as const;

type MetricKey = keyof typeof METRIC_COLUMNS;

function requireDates(from: string, to: string): void {
  if (!isDateString(from) || !isDateString(to)) {
    throw new Error(`invalid date (expected YYYY-MM-DD): ${from} / ${to}`);
  }
  if (from > to) {
    throw new Error(`from (${from}) must be <= to (${to})`);
  }
  const spanDays = Math.round((Date.parse(to + "T12:00:00") - Date.parse(from + "T12:00:00")) / 86400000) + 1;
  if (spanDays > MAX_RANGE_DAYS) {
    throw new Error(
      `range too wide: ${spanDays} days (max ${MAX_RANGE_DAYS}). ` +
        `Narrow the range or page through it — PostgREST truncates at 1000 rows.`,
    );
  }
}

function round2(n: number | null | undefined): number | null {
  return n === null || n === undefined ? null : Math.round(n * 100) / 100;
}

function avg(nums: (number | null)[]): number | null {
  const present = nums.filter((n): n is number => n !== null);
  if (present.length === 0) return null;
  return present.reduce((a, b) => a + b, 0) / present.length;
}

export interface HealthMetricsResult {
  from: string;
  to: string;
  metric: MetricKey | null;
  days: number;
  series: Record<string, string | number | null>[];
}

export async function getHealthMetrics(
  args: { from: string; to: string; metric?: MetricKey },
  store: DataStore,
): Promise<HealthMetricsResult> {
  requireDates(args.from, args.to);
  const rows = await store.healthMetrics(args.from, args.to);
  const cols = args.metric ? METRIC_COLUMNS[args.metric] : Object.values(METRIC_COLUMNS).flat();
  return {
    from: args.from,
    to: args.to,
    metric: args.metric ?? null,
    days: rows.length,
    series: rows.map((r) => {
      const out: Record<string, string | number | null> = { date: r.date };
      for (const c of cols) out[c] = r[c as keyof typeof r] ?? null;
      return out;
    }),
  };
}

export interface SessionDayAggregate {
  date: string;
  session_count: number;
  duration_min: number;
  load: number;
  avg_rpe: number | null;
  types: string[];
  phases: string[];
}

export interface SessionsResult {
  from: string;
  to: string;
  discipline: string | null;
  session_count: number;
  total_duration_min: number;
  total_load: number;
  avg_rpe: number | null;
  days: SessionDayAggregate[];
  attempts: {
    workout_count: number;
    attempts_confirmed: number;
    attempts_detected: number;
  };
  workouts: {
    started_at: string;
    ended_at: string;
    attempts_confirmed: number;
    attempts_detected: number;
    source: string;
  }[];
}

export async function getSessions(
  args: { from: string; to: string; discipline?: string },
  store: DataStore,
): Promise<SessionsResult> {
  requireDates(args.from, args.to);
  const discipline = args.discipline?.trim() || null;
  const rows = (await store.sessions(args.from, args.to)).filter(
    (s) => discipline === null || s.type === discipline,
  );

  const dayMap = new Map<string, SessionDayAggregate>();
  for (const s of rows) {
    let day = dayMap.get(s.date);
    if (!day) {
      day = { date: s.date, session_count: 0, duration_min: 0, load: 0, avg_rpe: null, types: [], phases: [] };
      dayMap.set(s.date, day);
    }
    day.session_count++;
    day.duration_min += s.duration_min;
    day.load += s.load;
    day.types.push(s.type_label);
    day.phases.push(s.phase);
  }
  for (const day of dayMap.values()) {
    day.avg_rpe = round2(avg(rows.filter((s) => s.date === day.date).map((s) => s.rpe)));
    day.types = [...new Set(day.types)];
    day.phases = [...new Set(day.phases)];
  }

  const workouts = await store.workouts(args.from, args.to);
  return {
    from: args.from,
    to: args.to,
    discipline,
    session_count: rows.length,
    total_duration_min: rows.reduce((a, s) => a + s.duration_min, 0),
    total_load: rows.reduce((a, s) => a + s.load, 0),
    avg_rpe: round2(avg(rows.map((s) => s.rpe))),
    days: [...dayMap.values()].sort((a, b) => a.date.localeCompare(b.date)),
    attempts: {
      workout_count: workouts.length,
      attempts_confirmed: workouts.reduce((a, w) => a + w.attempts_confirmed, 0),
      attempts_detected: workouts.reduce((a, w) => a + w.attempts_detected, 0),
    },
    workouts: workouts.map((w) => ({
      started_at: w.started_at,
      ended_at: w.ended_at,
      attempts_confirmed: w.attempts_confirmed,
      attempts_detected: w.attempts_detected,
      source: w.source,
    })),
  };
}

export interface ReadinessResult {
  days: number;
  from: string;
  to: string;
  series: { date: string; readiness: number | null; zone: string | null }[];
  latest: { date: string; readiness: number | null } | null;
  summary: {
    avg_readiness: number | null;
    min_readiness: number | null;
    max_readiness: number | null;
    low_readiness_days: number;
  };
}

export async function getReadiness(
  args: { days: number },
  store: DataStore,
): Promise<ReadinessResult> {
  const to = today();
  const from = daysAgo(args.days - 1);
  const rows = await store.healthMetrics(from, to);
  const series = rows.map((r) => ({ date: r.date, readiness: r.readiness, zone: r.zone }));
  const scores = rows.map((r) => r.readiness);
  return {
    days: args.days,
    from,
    to,
    series,
    latest:
      rows.length > 0
        ? { date: rows[rows.length - 1]!.date, readiness: rows[rows.length - 1]!.readiness }
        : null,
    summary: {
      avg_readiness: round2(avg(scores)),
      min_readiness: scores.some((s) => s !== null) ? Math.min(...scores.filter((s): s is number => s !== null)) : null,
      max_readiness: scores.some((s) => s !== null) ? Math.max(...scores.filter((s): s is number => s !== null)) : null,
      low_readiness_days: rows.filter((r) => r.readiness !== null && r.readiness < LOW_READINESS_THRESHOLD).length,
    },
  };
}

export interface AcwrResult {
  as_of: string;
  window_days: number;
  acute_7d_load: number;
  chronic_avg_load: number;
  acwr: number | null;
  status: string;
  phase: string | null;
  phase_started_on: string | null;
}

export async function getAcwr(
  args: { days: number },
  store: DataStore,
): Promise<AcwrResult> {
  const asOf = today();
  // The ratio is defined by the full 90-day EWMA window, not the caller's
  // display window — fetching anything shorter silently zero-fills days
  // 90..days and inflates the ratio (#644 review F3).
  const from = daysAgo(ACWR_FETCH_DAYS - 1);
  const sessions = (await store.sessions(from, asOf)).map(toLoadSession);
  const acwr = computeAcwr(sessions, asOf);
  const open = (await store.phasePeriods()).find((p) => p.ended_on === null);
  return {
    as_of: asOf,
    window_days: args.days,
    acute_7d_load: round2(acwr.acute) ?? 0,
    chronic_avg_load: round2(acwr.chronic) ?? 0,
    acwr: round2(acwr.acwr),
    status: acwrStatusLabel(acwr.acwr),
    phase: open?.phase ?? null,
    phase_started_on: open?.started_on ?? null,
  };
}

export interface TindeqPeak {
  t_ms: number;
  kg: number;
}

export interface TindeqResult {
  scope: { kind: "recording" | "session" | "recent"; id?: string; limit?: number };
  recordings: {
    id: string;
    recorded_at: string;
    duration_ms: number;
    peak_kg: number | null;
    avg_kg: number | null;
    sample_count: number;
    tag: string;
    side: string;
    zone: string | null;
    group_id: string | null;
    note: string;
  }[];
  summary: {
    recording_count: number;
    best_peak_kg: number | null;
    avg_peak_kg: number | null;
  };
  peaks: { recording_id: string; peaks: TindeqPeak[] }[];
}

export async function getTindeq(
  args: { recording_id?: string; session_id?: string; limit: number },
  store: DataStore,
): Promise<TindeqResult> {
  let recordings: RecordingRow[];
  let scope: TindeqResult["scope"];
  if (args.recording_id) {
    recordings = await store.recordingsByIds([args.recording_id]);
    scope = { kind: "recording", id: args.recording_id };
  } else if (args.session_id) {
    recordings = await store.recordingsByGroup(args.session_id);
    scope = { kind: "session", id: args.session_id };
  } else {
    recordings = await store.recentRecordings(args.limit);
    scope = { kind: "recent", limit: args.limit };
  }

  const peaks = await derivePeaks(recordings, store, scope.kind !== "recent");
  const peakKgs = recordings.map((r) => r.peak_kg);
  return {
    scope,
    recordings: recordings.map((r) => ({
      id: r.id,
      recorded_at: r.recorded_at,
      duration_ms: r.duration_ms,
      peak_kg: r.peak_kg,
      avg_kg: r.avg_kg,
      sample_count: r.sample_count,
      tag: r.tag,
      side: r.side,
      zone: r.zone,
      group_id: r.group_id,
      note: r.note,
    })),
    summary: {
      recording_count: recordings.length,
      best_peak_kg: peakKgs.some((k) => k !== null)
        ? Math.max(...peakKgs.filter((k): k is number => k !== null))
        : null,
      avg_peak_kg: round2(avg(peakKgs)),
    },
    peaks,
  };
}

/// Top local maxima per recording, derived from the stored samples
/// ([[t_ms, kg], ...] — t is milliseconds). Cap at 5 per recording.
async function derivePeaks(
  recordings: RecordingRow[],
  store: DataStore,
  includeSamples: boolean,
): Promise<{ recording_id: string; peaks: TindeqPeak[] }[]> {
  if (!includeSamples || recordings.length === 0) return [];
  const rows = await store.samplesByIds(recordings.map((r) => r.id));
  const byId = new Map(rows.map((r) => [r.id, r.samples ?? []]));
  return recordings.map((r) => ({ recording_id: r.id, peaks: topPeaks(byId.get(r.id) ?? [], 5) }));
}

/// Local maxima of a [[t_ms, kg], ...] series, best-first, ≤ maxPeaks. A
/// plateau counts once (its first sample); a flat run (no rise/fall at all)
/// is not a peak. A peak at the first or last sample is a genuine local
/// maximum and is kept (issue #644 review F14 — the old scan skipped the
/// endpoints and deduped by comparing kg to the previously-pushed entry,
/// which silently dropped a second peak of identical magnitude and any peak
/// at the final sample). Separate reps that happen to land on the same
/// rounded kg are all reported.
export function topPeaks(samples: [number, number][], maxPeaks: number): TindeqPeak[] {
  if (samples.length < 3) return [];
  const peaks: TindeqPeak[] = [];
  let i = 0;
  while (i < samples.length) {
    // Collapse the maximal run of equal samples starting at i into one
    // plateau candidate: [start, end), all kg === samples[i][1].
    let j = i;
    while (j < samples.length && samples[j]![1] === samples[i]![1]) j++;
    const left = i > 0 ? samples[i - 1]![1] : -Infinity;
    const right = j < samples.length ? samples[j]![1] : -Infinity;
    // A plateau is a peak when both sides are strictly lower — a flat run
    // with no sides (the whole series) is not a peak, and neither is one
    // edge of a longer same-value run (that's handled by collapsing).
    const isPeak = (i === 0 || left < samples[i]![1]) && (j === samples.length || right < samples[i]![1]);
    if (isPeak && (i > 0 || j < samples.length)) {
      peaks.push({ t_ms: samples[i]![0], kg: samples[i]![1] });
    }
    i = j;
  }
  peaks.sort((a, b) => b.kg - a.kg);
  return peaks.slice(0, maxPeaks);
}

export interface TrainingLoadResult {
  as_of: string;
  weeks: number;
  weekly_load: {
    week_index: number;
    label: string;
    start: string;
    end: string;
    total_load: number;
    session_count: number;
    avg_rpe: number | null;
  }[];
  load_trend: "increasing" | "decreasing" | "flat" | "insufficient_data";
  acwr: {
    acwr: number | null;
    status: string;
    acute_7d_load: number;
    chronic_avg_load: number;
  };
  recovery: {
    avg_readiness: number | null;
    low_readiness_days: number;
    readiness_trend: "declining" | "improving" | "stable" | "no_data";
  };
  phase: string | null;
  notes: string[];
}

export async function analyzeTrainingLoad(
  args: { weeks: number; days: number },
  store: DataStore,
): Promise<TrainingLoadResult> {
  const asOf = today();
  // The oldest weekly bucket starts weeks*7 - 1 days back and the EWMA needs
  // the full 90-day window, so the fetch must cover BOTH — never less than
  // the buckets need, or weeks>=13 fabricates zero-load weeks and flips the
  // trend (#644 review F4), and never less than the EWMA needs (#644 F3).
  const lookbackDays = Math.max(args.weeks * 7, ACWR_FETCH_DAYS, args.days);
  const from = daysAgo(lookbackDays - 1);
  const rows = await store.sessions(from, asOf);
  const sessions = rows.map(toLoadSession);
  const weekly = computeWeeklyLoads(sessions, asOf, args.weeks);

  const weeklyDetail = weekly.map((w) => {
    const inWeek = rows.filter((s) => s.date >= w.start && s.date <= w.end);
    return {
      week_index: w.weekIndex,
      label: w.weekIndex === 0 ? "Now" : `${w.weekIndex}w`,
      start: w.start,
      end: w.end,
      total_load: w.total,
      session_count: inWeek.length,
      avg_rpe: round2(avg(inWeek.map((s) => s.rpe))),
    };
  });

  const acwr = computeAcwr(sessions, asOf);
  const health = await store.healthMetrics(daysAgo(args.days - 1), asOf);
  const open = (await store.phasePeriods()).find((p) => p.ended_on === null);

  const notes = buildNotes(weeklyDetail, { acwr: acwr.acwr, status: acwrStatusLabel(acwr.acwr) }, health);
  return {
    as_of: asOf,
    weeks: args.weeks,
    weekly_load: weeklyDetail,
    load_trend: trendOf(weeklyDetail),
    acwr: {
      acwr: round2(acwr.acwr),
      status: acwrStatusLabel(acwr.acwr),
      acute_7d_load: round2(acwr.acute) ?? 0,
      chronic_avg_load: round2(acwr.chronic) ?? 0,
    },
    recovery: {
      avg_readiness: round2(avg(health.map((h) => h.readiness))),
      low_readiness_days: health.filter(
        (h) => h.readiness !== null && h.readiness < LOW_READINESS_THRESHOLD,
      ).length,
      readiness_trend: readinessTrendOf(health),
    },
    phase: open?.phase ?? null,
    notes,
  };
}

function toLoadSession(s: SessionRow): LoadSession {
  return { date: s.date, load: s.load };
}

function trendOf(
  weeks: { week_index: number; total_load: number; session_count: number }[],
): TrainingLoadResult["load_trend"] {
  const current = weeks.find((w) => w.week_index === 0);
  const prior = weeks.filter((w) => w.week_index > 0);
  if (!current || current.session_count === 0) return "insufficient_data";
  if (prior.length === 0 || prior.every((w) => w.session_count === 0)) return "insufficient_data";
  const priorAvg = prior.reduce((a, w) => a + w.total_load, 0) / prior.length;
  if (priorAvg === 0) return "insufficient_data";
  const delta = (current.total_load - priorAvg) / priorAvg;
  if (delta > 0.1) return "increasing";
  if (delta < -0.1) return "decreasing";
  return "flat";
}

function readinessTrendOf(
  health: { date: string; readiness: number | null }[],
): TrainingLoadResult["recovery"]["readiness_trend"] {
  const now = today();
  const last7 = health.filter((h) => h.date >= daysAgo(6) && h.date <= now).map((h) => h.readiness);
  const prior7 = health.filter((h) => h.date >= daysAgo(13) && h.date <= daysAgo(7)).map((h) => h.readiness);
  const a = avg(last7);
  const b = avg(prior7);
  if (a === null || b === null) return "no_data";
  const delta = a - b;
  if (delta <= -3) return "declining";
  if (delta >= 3) return "improving";
  return "stable";
}

function buildNotes(
  weeks: { week_index: number; total_load: number; session_count: number }[],
  acwr: { acwr: number | null; status: string },
  health: { date: string; readiness: number | null }[],
): string[] {
  const notes: string[] = [];
  const current = weeks.find((w) => w.week_index === 0);
  if (current && current.session_count === 0) {
    notes.push("No training sessions logged this week.");
  }
  if (acwr.acwr !== null && acwr.acwr > 1.5) {
    notes.push("ACWR is in the danger zone (>1.5): load is rising faster than fitness.");
  } else if (acwr.acwr !== null && acwr.acwr > 1.3) {
    notes.push("ACWR is in the caution zone (1.3–1.5): monitor for fatigue.");
  } else if (acwr.acwr !== null && acwr.acwr < 0.8) {
    notes.push("ACWR is low (<0.8): load may be underdosed for the current capacity.");
  }
  const low = health.filter((h) => h.readiness !== null && h.readiness < LOW_READINESS_THRESHOLD);
  if (low.length >= 3) {
    notes.push(
      `${low.length} of the last ${health.length} days read below the recovery threshold (readiness < ${LOW_READINESS_THRESHOLD}).`,
    );
  }
  if (readinessTrendOf(health) === "declining") {
    notes.push("Average readiness has declined over the last week.");
  }
  return notes;
}
