/// Pure merge/accumulation/staleness logic behind `useLiveWorkout` (#309,
/// #521). WatchConnectivity is the fast path and Supabase is the durable
/// fallback; both feeds are reduced through the same run/sequence cursor.

import type {
  LiveMirrorEvent,
  LiveWorkoutMessage,
} from "sendlog-auth-bridge";
import type { LiveWorkout } from "../types";

/// How long a heartbeat may go quiet before the workout is presumed dead
/// (watch upserts every ~5s; 30s of silence = app killed / walked away).
export const STALE_MS = 30_000;

/// Placeholder workout id for a WC beat that arrives before the initial
/// `fetchLiveWorkout()` resolves. The real run id is adopted as soon as a
/// Supabase row (or a current watch beat after one) arrives.
export const WC_PLACEHOLDER_ID = "wc-live";

export type LiveWorkoutSource = "watch-direct" | "server-fallback";

export interface LiveWorkoutMirrorState {
  row: LiveWorkout | null;
  hrLog: HrLog;
  source: LiveWorkoutSource;
}

export interface LiveWorkoutReduceResult {
  state: LiveWorkoutMirrorState;
  accepted: boolean;
}

const EVENTS: ReadonlySet<string> = new Set([
  "start",
  "telemetry",
  "phase",
  "count",
  "end",
]);

function eventFor(
  status: LiveWorkout["status"],
  event: string | undefined,
  terminal = false,
): LiveMirrorEvent {
  if (status === "ended" || terminal) return "end";
  return EVENTS.has(event ?? "") ? (event as LiveMirrorEvent) : "telemetry";
}

function safeSequence(value: unknown): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0
    ? value
    : null;
}

function normalizeRunId(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed ? trimmed.toLowerCase() : null;
}

function iso(sec: number | undefined): string | null {
  return sec !== undefined && Number.isFinite(sec)
    ? new Date(sec * 1000).toISOString()
    : null;
}

function legacyRunId(startedAt: string | null, previous: LiveWorkout | null): string {
  // Pre-#521 WC payloads have no run_id, but workout beats do carry their
  // start time. Deriving a stable fallback from it lets a new old-build run
  // replace a terminal previous run without allowing a late beat from that
  // previous run to re-open it. Keep the prior row only when the old payload
  // omitted even that timestamp.
  if (startedAt) {
    const ms = new Date(startedAt).getTime();
    if (Number.isFinite(ms)) return `legacy-workout-${ms}`;
  }
  return previous?.runId ?? WC_PLACEHOLDER_ID;
}

function terminalFor(
  status: LiveWorkout["status"],
  terminal: boolean | undefined,
): boolean {
  return status === "ended" || terminal === true;
}

/// WatchConnectivity beat → LiveWorkout (epoch seconds → ISO strings). The
/// WC path has no workout_id; carry the prior row's run/workout id so a beat
/// can join the durable row once the initial fetch resolves. The optional
/// sequence fields are intentionally normalized to null for old watch builds.
export function messageToLive(
  msg: LiveWorkoutMessage,
  prev: LiveWorkout | null,
): LiveWorkout {
  const status = msg.status;
  const startedAt = iso(msg.started_at) ?? prev?.startedAt ?? new Date().toISOString();
  const terminal = terminalFor(status, msg.terminal);
  const runId = normalizeRunId(msg.run_id) || legacyRunId(
    msg.started_at === undefined ? null : startedAt,
    prev,
  );
  return {
    // WC has no durable workout_id. Keep the placeholder until the Supabase
    // row arrives; runId still provides the #521 identity immediately.
    workoutId: prev?.workoutId ?? WC_PLACEHOLDER_ID,
    runId,
    sequence: safeSequence(msg.sequence),
    terminal,
    event: eventFor(status, msg.event, terminal),
    status,
    startedAt,
    hr: msg.hr ?? null,
    attemptCount: msg.attempt_count ?? 0,
    activeKcal: msg.active_kcal ?? null,
    elevationGainM: msg.elevation_gain_m ?? null,
    climbing: msg.climbing ?? false,
    climbingSince: msg.climbing_since === undefined
      ? prev?.climbingSince ?? null
      : iso(msg.climbing_since),
    restStartedAt: msg.rest_started_at === undefined
      ? prev?.restStartedAt ?? null
      : iso(msg.rest_started_at),
    restTargetS: msg.rest_target_s ?? null,
    updatedAt: iso(msg.updated_at) ?? new Date().toISOString(),
  };
}

export function rowToLive(row: Record<string, unknown>): LiveWorkout {
  const status = row.status as LiveWorkout["status"];
  const workoutId = String(row.workout_id);
  const normalizedRunId = normalizeRunId(row.run_id);
  const runId = normalizedRunId ?? workoutId;
  const terminal = terminalFor(status, row.terminal === true);
  return {
    workoutId,
    runId,
    sequence: safeSequence(row.sequence),
    terminal,
    event: eventFor(
      status,
      typeof row.event === "string" ? row.event : undefined,
      terminal,
    ),
    status,
    startedAt: row.started_at as string,
    hr: row.hr as number | null,
    attemptCount: row.attempt_count as number,
    activeKcal: row.active_kcal as number | null,
    elevationGainM: row.elevation_gain_m as number | null,
    climbing: row.climbing as boolean,
    climbingSince: (row.climbing_since as string | null) ?? null,
    restStartedAt: (row.rest_started_at as string | null) ?? null,
    restTargetS: (row.rest_target_s as number | null) ?? null,
    updatedAt: row.updated_at as string,
  };
}

function isFreshRun(previous: LiveWorkout, incoming: LiveWorkout): boolean {
  if (previous.runId === WC_PLACEHOLDER_ID) return true;
  if (incoming.runId === WC_PLACEHOLDER_ID) return false;
  if (previous.runId === incoming.runId) return true;

  // UUIDs are opaque. The start timestamp is the only safe mixed-version
  // ordering signal for an old run arriving after a new run. Equal starts are
  // treated as current to preserve a just-created run during the fetch/WC
  // race; the run/sequence cursor then handles all subsequent packets.
  return new Date(incoming.startedAt).getTime() >= new Date(previous.startedAt).getTime();
}

/// Returns whether `incoming` can replace `previous`. Terminal beats are
/// intentionally accepted before the normal freshness comparison, then the
/// terminal previous row rejects every later live beat for that run.
export function acceptsLiveWorkout(
  previous: LiveWorkout | null,
  incoming: LiveWorkout,
): boolean {
  if (!previous) return true;
  if (!isFreshRun(previous, incoming)) return false;
  if (previous.runId !== incoming.runId) return true;
  if (previous.terminal) return false;
  if (incoming.terminal) return true;

  if (previous.sequence !== null && incoming.sequence !== null) {
    return incoming.sequence > previous.sequence;
  }
  // Mixed-version fallback. Equal timestamps remain readable, but HR series
  // dedupe below still refuses a duplicate point.
  return new Date(incoming.updatedAt).getTime() >= new Date(previous.updatedAt).getTime();
}

/// WC-vs-realtime freshness race: keep whichever source is newest according
/// to run identity + sequence, with the terminal override described above.
export function preferFresher(
  prev: LiveWorkout | null,
  incoming: LiveWorkout,
): LiveWorkout {
  return acceptsLiveWorkout(prev, incoming) ? incoming : (prev as LiveWorkout);
}

/// One point of the client-accumulated live HR series (SL-90) — every
/// accepted heartbeat's HR reading, collected while the mirror is open so the
/// fullscreen can chart the workout's HR in real time.
export interface LiveHrPoint {
  t: number; // ms epoch of the beat
  hr: number;
}

export interface HrLog {
  id: string;
  pts: LiveHrPoint[];
}

/// Appends `next`'s HR reading to the series. A placeholder→real id
/// transition carries the series forward. Duplicate/out-of-order timestamps
/// are dropped even when a legacy packet has no sequence number.
export function appendHrPoint(prev: HrLog, next: LiveWorkout): HrLog {
  if (next.status !== "live" || next.terminal || next.hr === null) return prev;
  const pt: LiveHrPoint = { t: new Date(next.updatedAt).getTime(), hr: next.hr };
  if (prev.id !== next.runId) {
    const carried = prev.id === WC_PLACEHOLDER_ID ? prev.pts : [];
    const last = carried[carried.length - 1];
    if (last && pt.t <= last.t) return { id: next.runId, pts: carried };
    return { id: next.runId, pts: [...carried, pt] };
  }
  const last = prev.pts[prev.pts.length - 1];
  if (last && pt.t <= last.t) return prev;
  return { id: prev.id, pts: [...prev.pts, pt] };
}

/// Reducer used by the hook. It updates the ref-owned current state before
/// React is notified, so an async WC/realtime callback cannot make a decision
/// from a stale render closure.
export function reduceLiveWorkout(
  previous: LiveWorkoutMirrorState,
  incoming: LiveWorkout,
  source: LiveWorkoutSource,
): LiveWorkoutReduceResult {
  if (!acceptsLiveWorkout(previous.row, incoming)) {
    return { state: previous, accepted: false };
  }
  return {
    accepted: true,
    state: {
      row: incoming,
      hrLog: appendHrPoint(previous.hrLog, incoming),
      source,
    },
  };
}

/// The hook's final visible state: hides an ended/missing/stale row and only
/// surfaces the HR series when it belongs to the currently-visible run.
export function visibleLiveWorkout(
  row: LiveWorkout | null,
  hrLog: HrLog,
  nowMs: number,
): [LiveWorkout | null, LiveHrPoint[]] {
  if (!row || row.status !== "live" || row.terminal) return [null, []];
  if (nowMs - new Date(row.updatedAt).getTime() > STALE_MS) return [null, []];
  return [row, hrLog.id === row.runId ? hrLog.pts : []];
}
