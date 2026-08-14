// #615: optimistic completed-workout sessions. A phone workout's save is
// visible in History the moment it ends (pending marker); a watch workout
// reaches the phone as a `workoutCompleted` WatchConnectivity notification
// with the same pending semantics. Server data reconciles by the STABLE
// session id — retries, realtime echoes, app foregrounds and process
// restarts all converge on the same row, never a duplicate.
//
// All functions here are pure so the race cases (realtime before/after
// reconcile, notification replay, account change mid-flight) are unit-tested
// without React or a network.

import type { PhaseId, Session } from "../types";
import { today } from "./dates";

/// A locally-minted session row that has not reached the server yet.
export interface PendingWorkout extends Session {
  pending: true;
  accountUserId: string;
}

export function sortPendingSessions(list: Session[]): Session[] {
  return [...list].sort((a, b) => b.date.localeCompare(a.date));
}

/// The phone save clamps the recorded span to the sessions.duration_min
/// check constraint (1..600), mirroring the old sequential insert and the
/// RPC it now calls — the pending row and the server row must agree.
export function workoutDurationMin(startedAt: string, endedAt: string): number {
  return Math.max(
    1,
    Math.min(
      600,
      Math.round(
        (new Date(endedAt).getTime() - new Date(startedAt).getTime()) / 60000,
      ),
    ),
  );
}

function boulderNote(n: number): string {
  return `${n} boulder${n === 1 ? "" : "s"}`;
}

/// Build the pending row for a PHONE workout from the reducer's confirming
/// state + save metadata. Ids were minted when the workout ended and are
/// persisted in the reducer state, so a retry after a restart reuses them.
export function pendingSessionFromPhoneWorkout(input: {
  sessionId: string;
  startedAt: string;
  endedAt: string;
  attempts: { startedAt: string; durationS: number }[];
  type: string;
  typeLabel: string;
  rpe: number;
  phase: PhaseId;
  accountUserId: string;
}): PendingWorkout {
  const duration = workoutDurationMin(input.startedAt, input.endedAt);
  const n = input.attempts.length;
  return {
    id: input.sessionId,
    date: today(),
    type: input.type,
    typeLabel: input.typeLabel,
    duration,
    rpe: input.rpe,
    // Unconfirmed until the user edits it away from the auto-save default
    // (issue #114) — the server row is written with rpe_confirmed = false.
    rpeConfirmed: false,
    load: duration * input.rpe,
    note: boulderNote(n),
    phase: input.phase,
    groupId: null,
    workoutSource: "phone",
    pending: true,
    accountUserId: input.accountUserId,
  };
}

/// Build the pending row for a WATCH workout from the `workoutCompleted`
/// notification. Returns null when the payload lacks the fields a real
/// message always carries (schema drift — skip rather than render garbage).
export function pendingSessionFromWatchMessage(
  msg: {
    session_id?: string;
    workout_id?: string;
    started_at?: number;
    ended_at?: number;
    attempt_count?: number;
    duration_min?: number;
    rpe?: number;
    phase?: string;
    type?: string;
    type_label?: string;
    note?: string;
    rpe_confirmed?: boolean;
  },
  accountUserId: string,
): PendingWorkout | null {
  const sessionId = msg.session_id;
  const startedAt = msg.started_at;
  const duration = msg.duration_min;
  const rpe = msg.rpe;
  if (!sessionId || !startedAt || !duration || !rpe) return null;
  const n = msg.attempt_count ?? 0;
  return {
    id: sessionId,
    date: dateStr(new Date(startedAt * 1000)),
    type: msg.type ?? "auto",
    typeLabel: msg.type_label ?? "Auto-tracked",
    duration,
    rpe,
    // The watch's session row is written with the SessionInsert default
    // (rpe_confirmed = true) — the pending row must match the eventual
    // server row, so an absent key defaults to true as well.
    rpeConfirmed: msg.rpe_confirmed ?? true,
    load: Math.round(duration * rpe),
    note: msg.note ?? boulderNote(n),
    phase: (msg.phase as PhaseId) ?? "capacity",
    groupId: null,
    workoutSource: "watch",
    pending: true,
    accountUserId,
  };
}

/// A fetch result reconciled against the local list: every fetched row wins
/// by id (a pending row whose server row just landed becomes the canonical
/// row), and pending rows not on the server yet survive the refetch. Pending
/// rows stamped for a DIFFERENT account are dropped — an account switch must
/// not carry the old account's optimistic row into the new account's view.
export function mergeFetchedSessions(
  list: Session[],
  fetched: Session[],
  accountUserId: string,
): Session[] {
  const fetchedIds = new Set(fetched.map((s) => s.id));
  const keptPending = list.filter(
    (s) =>
      s.pending &&
      s.accountUserId === accountUserId &&
      !fetchedIds.has(s.id),
  );
  return sortPendingSessions([...fetched, ...keptPending]);
}

/// Idempotent registration of a pending row: a duplicate notification (watch
/// re-send, a stored payload drained twice) replaces by id instead of
/// appending. The row is sorted into place like any other.
export function upsertPendingSession(
  list: Session[],
  pending: PendingWorkout,
): Session[] {
  const present = list.some((s) => s.id === pending.id);
  return sortPendingSessions(
    present ? list.map((s) => (s.id === pending.id ? pending : s)) : [...list, pending],
  );
}

/// Reconcile by id: the canonical server row for a pending id arrived (the
/// RPC's return, a realtime INSERT payload, or a refetch). Replaces in place
/// and drops the pending marker with the server row's own truth.
export function reconcilePendingSession(
  list: Session[],
  saved: Session,
): Session[] {
  const present = list.some((s) => s.id === saved.id);
  return sortPendingSessions(
    present ? list.map((s) => (s.id === saved.id ? saved : s)) : [...list, saved],
  );
}

/// Roll back a pending row by id after the save failed (nothing durable
/// exists for it). Only removes a row that is still pending — a canonical
/// row already reconciled under the same id is never dropped here.
export function rollbackPendingSession(list: Session[], id: string): Session[] {
  return list.filter((s) => s.id !== id || !s.pending);
}

/// Drop every pending row, optionally only those for a specific session id.
/// Used when the account changes (the rows belong to a different session
/// family) or the save is abandoned.
export function dropPendingForAccount(
  list: Session[],
  accountUserId: string,
): Session[] {
  return list.filter((s) => !s.pending || s.accountUserId === accountUserId);
}

export function dateStr(d: Date): string {
  const y = d.getFullYear();
  const m = `${d.getMonth() + 1}`.padStart(2, "0");
  const day = `${d.getDate()}`.padStart(2, "0");
  return `${y}-${m}-${day}`;
}
