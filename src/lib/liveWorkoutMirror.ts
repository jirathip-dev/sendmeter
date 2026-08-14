/// Pure merge/accumulation/staleness logic behind `useLiveWorkout` (#309,
/// #521). WatchConnectivity is the fast path and Supabase is the durable
/// fallback; both feeds are reduced through the same run/sequence cursor.

import type {
  LiveMirrorEvent,
  LiveWorkoutMessage,
} from "sendlog-auth-bridge";
import type { LiveWorkout } from "../types";
import { acceptsPacketOwner } from "./liveMirrorOwnership";
import type { LiveMirrorRejection } from "./liveMirrorTelemetry";

/// How long a heartbeat may go quiet before the workout is presumed dead
/// (watch upserts every ~5s; 30s of silence = app killed / walked away).
export const STALE_MS = 30_000;

/// How long the row may go quiet (by the phone's own clock since the last
/// ACCEPTED packet — see `lastAcceptedAtMs`) before the phone stops claiming a
/// working link. Beyond this the card must say the link is paused even if the
/// last accepted message came over WC — the mirror is showing the last update,
/// not a live one. ~2 workout heartbeat intervals. Phone-local, so device
/// clock skew cannot trip it (#614 review F8).
export const DIRECT_QUIET_MS = 10_000;

/// Honest transport state for the live workout card (#614). `watch-direct`
/// and `server-fallback` name the transport of the last accepted message;
/// `temporarily-unreachable` means the phone has not accepted anything for
/// `DIRECT_QUIET_MS` — neither path has delivered anything fresh — and
/// `unknown` covers "no live row / ended / nothing known yet". Unknown must
/// never be presented as healthy.
export type LiveWorkoutSyncState =
  | "watch-direct"
  | "server-fallback"
  | "temporarily-unreachable"
  | "unknown";

/// Placeholder workout id for a WC beat that arrives before the initial
/// `fetchLiveWorkout()` resolves. The real run id is adopted as soon as a
/// Supabase row (or a current watch beat after one) arrives.
export const WC_PLACEHOLDER_ID = "wc-live";

export type LiveWorkoutSource = "watch-direct" | "server-fallback";

export interface LiveWorkoutMirrorState {
  row: LiveWorkout | null;
  hrLog: HrLog;
  source: LiveWorkoutSource;
  /// Phone-local wall-clock ms when the last packet was ACCEPTED into this
  /// cursor. Quiet-state derivation compares against this (same clock), never
  /// against `row.updatedAt` (a watch/DB clock) — #614 review F8: comparing a
  /// phone clock to a device clock makes a watch lagging >10s read
  /// "temporarily unreachable" forever.
  lastAcceptedAtMs: number;
}

/// Empty cursor state for a newly authenticated account. Hooks reset this
/// value before subscribing to the next user's channel so an older account's
/// high sequence can never reject the new account's first (possibly older)
/// run.
export function emptyLiveWorkoutMirrorState(): LiveWorkoutMirrorState {
  return {
    row: null,
    hrLog: { id: "", pts: [] },
    source: "server-fallback",
    lastAcceptedAtMs: 0,
  };
}

export interface LiveWorkoutReduceResult {
  state: LiveWorkoutMirrorState;
  accepted: boolean;
  /// Why a packet was rejected, present only when `accepted` is false.
  /// Telemetry records this so a diagnosis can name the failure instead of a
  /// bare "not applied".
  rejection?: LiveMirrorRejection;
}

/// Classifies a rejected workout packet. Deliberately mirrors the guards in
/// `acceptsLiveWorkout` IN ORDER — run freshness before terminal dominance
/// (#614 review F11) — so a packet from an older run arriving after a
/// terminal row reads as `staleRun`, not `afterTerminal`.
export function rejectionForWorkout(
  previous: LiveWorkout | null,
  incoming: LiveWorkout,
): LiveMirrorRejection {
  if (previous && !isFreshRun(previous, incoming)) return "staleRun";
  if (previous?.terminal) return "afterTerminal";
  if (previous && previous.sequence !== null && incoming.sequence !== null) {
    return incoming.sequence < previous.sequence ? "outOfOrder" : "duplicate";
  }
  return "notFresh";
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
/// from a stale render closure. `nowMs` (phone wall clock) stamps the state's
/// `lastAcceptedAtMs` so quiet-state derivation is clock-skew-free (#614 F8).
export function reduceLiveWorkout(
  previous: LiveWorkoutMirrorState,
  incoming: LiveWorkout,
  source: LiveWorkoutSource,
  nowMs: number = Date.now(),
): LiveWorkoutReduceResult {
  if (!acceptsLiveWorkout(previous.row, incoming)) {
    return {
      state: previous,
      accepted: false,
      rejection: rejectionForWorkout(previous.row, incoming),
    };
  }
  return {
    accepted: true,
    state: {
      row: incoming,
      hrLog: appendHrPoint(previous.hrLog, incoming),
      source,
      lastAcceptedAtMs: nowMs,
    },
  };
}

export interface LiveWorkoutAdmissionResult extends LiveWorkoutReduceResult {
  /// True when this admission is positive evidence the watch has caught up
  /// to a #530-aware build — a genuinely STAMPED (not legacy-absent) packet
  /// was accepted. Callers should durably clear the transition marker via
  /// `recordStampedPacketAccepted` in `liveMirrorOwnership.ts`.
  stampedAcceptance: boolean;
}

/// The FULL WatchConnectivity packet admission pipeline for one incoming
/// message, in one call: the account-ownership guard (#530), then
/// `messageToLive`, then `reduceLiveWorkout` — a rejected owner never
/// reaches the reducer at all. Round-2 review R2-F6: this is the ONLY
/// function `useLiveWorkout`'s WC listener calls, so a test exercising this
/// function directly is exercising the exact wiring that ships — deleting
/// the ownership guard from inside this function (as opposed to a hook-side
/// call the test suite cannot reach) is caught by
/// `liveMirrorOwnership.test.ts`'s late-A-after-B coverage.
export function admitLiveWorkoutMessage(
  previous: LiveWorkoutMirrorState,
  msg: LiveWorkoutMessage,
  currentUserId: string,
  hasHadAccountTransition: boolean,
  nowMs: number = Date.now(),
): LiveWorkoutAdmissionResult {
  if (!acceptsPacketOwner(msg.account_user_id, currentUserId, hasHadAccountTransition)) {
    return {
      state: previous,
      accepted: false,
      stampedAcceptance: false,
      rejection: "ownerMismatch",
    };
  }
  const incoming = messageToLive(msg, previous.row);
  const reduced = reduceLiveWorkout(previous, incoming, "watch-direct", nowMs);
  return { ...reduced, stampedAcceptance: msg.account_user_id !== undefined };
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

/// Honest transport state for the currently-visible row, derived from the
/// mirror cursor and the phone clock at render time (#614). Quietness is
/// measured from `lastAcceptedAtMs` — the phone's OWN clock when it last
/// accepted a packet — NOT from `row.updatedAt` (a watch/DB clock): a phone
/// clock compared to a device clock is exactly the skew that would read a
/// healthy direct link as paused forever (#614 review F8). If neither path
/// has delivered anything fresh for `DIRECT_QUIET_MS`, the card must not
/// claim a working link.
export function deriveLiveWorkoutSyncState(
  state: LiveWorkoutMirrorState,
  nowMs: number,
): LiveWorkoutSyncState {
  const row = state.row;
  if (!row || row.status !== "live" || row.terminal) return "unknown";
  const quietAgeMs = nowMs - state.lastAcceptedAtMs;
  if (quietAgeMs > STALE_MS) return "unknown";
  if (quietAgeMs > DIRECT_QUIET_MS) return "temporarily-unreachable";
  return state.source;
}
