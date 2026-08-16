/// The server's entire data-access surface. `DataStore` is READ-ONLY by
/// construction: every method is a SELECT, and the implementation never
/// reaches for an insert/update/delete/upsert/rpc — that property is pinned
/// structurally by test/invariants.test.ts, which scans this module's
/// PostgREST call sites and the shipped source for mutation verbs.
///
/// The transport is injectable (custom `fetch`) so unit tests exercise the
/// real query-building code path against a recorded mock and never touch the
/// network.

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { localDayRange } from "./dates.js";

export interface HealthMetricsRow {
  date: string;
  readiness: number | null;
  zone: string | null;
  computed_at: string | null;
  hrv_sdnn_ms: number | null;
  resting_hr: number | null;
  sleep_hours: number | null;
  sleep_deep_hours: number | null;
  sleep_rem_hours: number | null;
  body_mass_kg: number | null;
  resp_rate_bpm: number | null;
}

export interface SessionRow {
  id: string;
  date: string;
  type: string;
  type_label: string;
  duration_min: number;
  rpe: number;
  rpe_confirmed: boolean;
  load: number;
  note: string;
  phase: string;
  group_id: string | null;
  workout_source: string | null;
}

export interface PhasePeriodRow {
  id: string;
  phase: string;
  started_on: string;
  ended_on: string | null;
}

export interface WorkoutRow {
  session_id: string | null;
  started_at: string;
  ended_at: string;
  attempts_detected: number;
  attempts_confirmed: number;
  source: string;
}

export interface RecordingRow {
  id: string;
  recorded_at: string;
  duration_ms: number;
  peak_kg: number | null;
  avg_kg: number | null;
  sample_count: number;
  note: string;
  tag: string;
  side: string;
  group_id: string | null;
  zone: string | null;
  source: string;
}

export interface SampleRow {
  id: string;
  /// [[t_ms, kg], ...] — t in milliseconds (the web's recording-sample unit).
  samples: [number, number][] | null;
}

export interface DataStore {
  healthMetrics(from: string, to: string): Promise<HealthMetricsRow[]>;
  sessions(from: string, to: string): Promise<SessionRow[]>;
  phasePeriods(): Promise<PhasePeriodRow[]>;
  workouts(from: string, to: string): Promise<WorkoutRow[]>;
  recordingsByGroup(groupId: string): Promise<RecordingRow[]>;
  recordingsByIds(ids: string[]): Promise<RecordingRow[]>;
  recentRecordings(limit: number): Promise<RecordingRow[]>;
  samplesByIds(ids: string[]): Promise<SampleRow[]>;
}

const HEALTH_COLS =
  "date, readiness, zone, computed_at, hrv_sdnn_ms, resting_hr, sleep_hours, sleep_deep_hours, sleep_rem_hours, body_mass_kg, resp_rate_bpm";

const SESSION_COLS =
  "id, date, type, type_label, duration_min, rpe, rpe_confirmed, load, note, phase, group_id, workout_source";

const RECORDING_COLS =
  "id, recorded_at, duration_ms, peak_kg, avg_kg, sample_count, note, tag, side, group_id, zone, source";

/// Build the read-only store against a Supabase project. The caller's access
/// token is pinned as a static Bearer header — this client has no auth
/// machinery of its own, nothing to refresh, nothing to write. RLS scopes
/// every query to the token's user (auth.uid()).
export function createSupabaseStore(opts: {
  url: string;
  anonKey: string;
  accessToken: string;
  fetch?: typeof fetch;
}): DataStore {
  const client: SupabaseClient = createClient(opts.url, opts.anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: opts.fetch,
      headers: { Authorization: `Bearer ${opts.accessToken}` },
    },
  });
  return {
    async healthMetrics(from, to) {
      const { data, error } = await client
        .from("health_metrics")
        .select(HEALTH_COLS)
        .gte("date", from)
        .lte("date", to)
        .order("date", { ascending: true });
      if (error) throw new Error(`health_metrics: ${error.message}`);
      return (data ?? []) as HealthMetricsRow[];
    },
    async sessions(from, to) {
      const { data, error } = await client
        .from("sessions")
        .select(SESSION_COLS)
        .is("deleted_at", null)
        .gte("date", from)
        .lte("date", to)
        .order("date", { ascending: true })
        .order("created_at", { ascending: true });
      if (error) throw new Error(`sessions: ${error.message}`);
      return (data ?? []) as SessionRow[];
    },
    async phasePeriods() {
      const { data, error } = await client
        .from("phase_periods")
        .select("id, phase, started_on, ended_on")
        .order("started_on", { ascending: true });
      if (error) throw new Error(`phase_periods: ${error.message}`);
      return (data ?? []) as PhasePeriodRow[];
    },
    async workouts(from, to) {
      const { start, end } = localDayRange(to);
      const startOfFrom = localDayRange(from).start;
      const { data, error } = await client
        .from("climb_workouts")
        .select("session_id, started_at, ended_at, attempts_detected, attempts_confirmed, source")
        .gte("started_at", startOfFrom)
        .lt("started_at", end)
        .order("started_at", { ascending: true });
      if (error) throw new Error(`climb_workouts: ${error.message}`);
      return (data ?? []) as WorkoutRow[];
    },
    async recordingsByGroup(groupId) {
      const { data, error } = await client
        .from("tindeq_recordings")
        .select(RECORDING_COLS)
        .eq("group_id", groupId)
        .is("deleted_at", null)
        .order("recorded_at", { ascending: true });
      if (error) throw new Error(`tindeq_recordings: ${error.message}`);
      return (data ?? []) as RecordingRow[];
    },
    async recordingsByIds(ids) {
      if (ids.length === 0) return [];
      const { data, error } = await client
        .from("tindeq_recordings")
        .select(RECORDING_COLS)
        .in("id", ids)
        .is("deleted_at", null)
        .order("recorded_at", { ascending: true });
      if (error) throw new Error(`tindeq_recordings: ${error.message}`);
      return (data ?? []) as RecordingRow[];
    },
    async recentRecordings(limit) {
      const { data, error } = await client
        .from("tindeq_recordings")
        .select(RECORDING_COLS)
        .is("deleted_at", null)
        .order("recorded_at", { ascending: false })
        .limit(limit);
      if (error) throw new Error(`tindeq_recordings: ${error.message}`);
      return (data ?? []) as RecordingRow[];
    },
    async samplesByIds(ids) {
      if (ids.length === 0) return [];
      const { data, error } = await client
        .from("tindeq_recordings")
        .select("id, samples")
        .in("id", ids)
        .is("deleted_at", null);
      if (error) throw new Error(`tindeq_recordings: ${error.message}`);
      return (data ?? []) as SampleRow[];
    },
  };
}
