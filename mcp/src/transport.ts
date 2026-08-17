/// The server's entire data-access surface. `DataStore` is READ-ONLY by
/// construction: every method is a SELECT, and the implementation never
/// reaches for an insert/update/delete/upsert/rpc — that property is pinned
/// structurally by test/invariants.test.ts, which scans this module's
/// PostgREST call sites and the shipped source for mutation verbs.
///
/// The transport is injectable (custom `fetch`) so unit tests exercise the
/// real query-building code path against a recorded mock and never touch the
/// network.
///
/// The token is NOT pinned at construction (issue #644 review F5). A
/// `TokenProvider` re-reads the current access token on every request, and
/// when PostgREST rejects it (HTTP 401) the store re-authenticates through
/// the provider and retries the query exactly once. Expiry therefore never
/// produces a silently-wrong or half-truncated answer: it either rotates to a
/// fresh token (same user, via a password sign-in) or surfaces a structured
/// error telling the caller to re-authenticate. PostgREST's internal retry
/// loop is disabled so those paths stay deterministic instead of stalling on
/// exponential backoff.

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { localDayRange } from "./dates.js";

/// Supplies the current access token (memory-only, see auth.ts). `get()`
/// throws when no token can be produced (expired + no credentials); the
/// store surfaces that as a structured error. `onUnauthorized()` is invoked
/// after a 401 so the provider can rotate the token before the retry.
export interface TokenProvider {
  get(): Promise<string>;
  onUnauthorized(): Promise<void>;
}

/// Raised when a request comes back 401 and even a re-authenticated retry
/// was rejected (or no credentials exist to re-authenticate). The server
/// wraps it in a structured `isError` result — never a crash, never a guess.
export class AuthRequiredError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AuthRequiredError";
  }
}

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

function queryError(table: string, error: unknown, status: number | undefined): never {
  const message = (error as { message?: string } | null)?.message ?? String(error);
  if (status === 401) {
    throw new AuthRequiredError(
      `${table}: token rejected (HTTP 401) — re-authenticate and retry: ${message}`,
    );
  }
  throw new Error(`${table}: ${message}`);
}

interface QueryResult<T> {
  data: T | null;
  error: { message?: string } | null;
  status?: number;
}

/// Run a query builder expression, re-authenticating and retrying exactly
/// once when the server rejects the token (401). A second 401 (or a provider
/// that cannot re-authenticate) surfaces as AuthRequiredError.
async function exec<T>(
  table: string,
  tokenProvider: TokenProvider,
  run: () => Promise<QueryResult<T>>,
): Promise<T> {
  let res = await run();
  if (res.error && res.status === 401) {
    await tokenProvider.onUnauthorized();
    res = await run();
  }
  if (res.error) queryError(table, res.error, res.status);
  return (res.data ?? []) as T;
}

/// Build the read-only store against a Supabase project. The caller's access
/// token is re-read per request from the TokenProvider (in-memory, rotatable
/// on 401 — see auth.ts); this client has no auth machinery of its own,
/// nothing to refresh, nothing to write. RLS scopes every query to the
/// token's user (auth.uid()).
export function createSupabaseStore(opts: {
  url: string;
  anonKey: string;
  tokenProvider: TokenProvider;
  fetch?: typeof fetch;
}): DataStore {
  const client: SupabaseClient = createClient(opts.url, opts.anonKey, {
    // Top-level `accessToken` provider (NOT the `auth` namespace): the data
    // client gets its bearer from the provider on every request, so a token
    // rotated after a 401 takes effect on the retry. When this option is set
    // supabase-js forbids touching `client.auth` — exactly the #265
    // "nothing to refresh inside the data client" shape.
    accessToken: () => opts.tokenProvider.get(),
    // Retries are owned by exec() above (which retries only after re-auth);
    // postgrest-js's own backoff loop would turn a token-provider failure
    // into a ~7s stall before surfacing it.
    db: { retry: false },
    global: { fetch: opts.fetch },
  });

  return {
    async healthMetrics(from, to) {
      return exec("health_metrics", opts.tokenProvider, async () => {
        const res = await client
          .from("health_metrics")
          .select(HEALTH_COLS)
          .gte("date", from)
          .lte("date", to)
          .order("date", { ascending: true });
        return res as QueryResult<HealthMetricsRow[]>;
      });
    },
    async sessions(from, to) {
      return exec("sessions", opts.tokenProvider, async () => {
        const res = await client
          .from("sessions")
          .select(SESSION_COLS)
          .is("deleted_at", null)
          .gte("date", from)
          .lte("date", to)
          .order("date", { ascending: true })
          .order("created_at", { ascending: true });
        return res as QueryResult<SessionRow[]>;
      });
    },
    async phasePeriods() {
      return exec("phase_periods", opts.tokenProvider, async () => {
        const res = await client
          .from("phase_periods")
          .select("id, phase, started_on, ended_on")
          .order("started_on", { ascending: true });
        return res as QueryResult<PhasePeriodRow[]>;
      });
    },
    async workouts(from, to) {
      const startOfFrom = localDayRange(from).start;
      const endOfTo = localDayRange(to).end;
      return exec("climb_workouts", opts.tokenProvider, async () => {
        const res = await client
          .from("climb_workouts")
          .select("session_id, started_at, ended_at, attempts_detected, attempts_confirmed, source")
          .gte("started_at", startOfFrom)
          .lt("started_at", endOfTo)
          .order("started_at", { ascending: true });
        return res as QueryResult<WorkoutRow[]>;
      });
    },
    async recordingsByGroup(groupId) {
      return exec("tindeq_recordings", opts.tokenProvider, async () => {
        const res = await client
          .from("tindeq_recordings")
          .select(RECORDING_COLS)
          .eq("group_id", groupId)
          .is("deleted_at", null)
          .order("recorded_at", { ascending: true });
        return res as QueryResult<RecordingRow[]>;
      });
    },
    async recordingsByIds(ids) {
      if (ids.length === 0) return [];
      return exec("tindeq_recordings", opts.tokenProvider, async () => {
        const res = await client
          .from("tindeq_recordings")
          .select(RECORDING_COLS)
          .in("id", ids)
          .is("deleted_at", null)
          .order("recorded_at", { ascending: true });
        return res as QueryResult<RecordingRow[]>;
      });
    },
    async recentRecordings(limit) {
      return exec("tindeq_recordings", opts.tokenProvider, async () => {
        const res = await client
          .from("tindeq_recordings")
          .select(RECORDING_COLS)
          .is("deleted_at", null)
          .order("recorded_at", { ascending: false })
          .limit(limit);
        return res as QueryResult<RecordingRow[]>;
      });
    },
    async samplesByIds(ids) {
      if (ids.length === 0) return [];
      return exec("tindeq_recordings", opts.tokenProvider, async () => {
        const res = await client
          .from("tindeq_recordings")
          .select("id, samples")
          .in("id", ids)
          .is("deleted_at", null);
        return res as QueryResult<SampleRow[]>;
      });
    },
  };
}
