// #615: apply a `sessions` postgres_changes INSERT payload directly to the
// training state by id — the fast reconcile path for a pending watch/phone
// workout whose server row just landed. The pure logic lives here so the
// exactly-once overlap rules (realtime before/after an optimistic reconcile)
// are testable without React or a live realtime channel.

import type { Session } from "../types";
import { toSession, type SessionRow } from "./repo/sessions";
import { sortPendingSessions } from "./pendingWorkouts";

/// One `sessions` postgres_changes event, narrowed to what the apply path
/// needs. Produced by RealtimeVersionProvider, applied by useTrainingData.
export interface RealtimeSessionRowEvent {
  eventType: "INSERT" | "UPDATE" | "DELETE";
  row: Record<string, unknown> | null;
  oldRow: Record<string, unknown> | null;
}

/// `toSession` is tolerant (missing fields parse to defaults, not a throw),
/// so a malformed realtime row would otherwise become a bogus session.
/// Require the fields a real row always has before letting it through;
/// anything else is skipped and the refetch reconciles via a full fetch.
function isParsableSessionRow(row: Record<string, unknown> | null): boolean {
  if (!row) return false;
  return (
    typeof row.id === "string" &&
    typeof row.date === "string" &&
    typeof row.type === "string" &&
    typeof row.duration_min === "number" &&
    typeof row.load === "number"
  );
}

/// Apply ONE realtime event to a sessions list, by id. Only INSERT events
/// are applied — an UPDATE (e.g. a soft delete) or DELETE stays on the
/// refetch path, because the session list is also the ACWR/phase input and
/// a delete needs the full reconciled list, not a local guess.
///
/// An INSERT is an idempotent upsert: a row already present (the pending
/// placeholder, or a canonical row the refetch already landed) is REPLACED
/// by the server's truth — which is exactly what reconciles a pending
/// workout exactly once however many times the event or the optimistic
/// registration happens to fire. A row never seen before is appended.
function applySessionRealtimeEvent(
  list: readonly Session[],
  event: RealtimeSessionRowEvent,
): Session[] {
  if (event.eventType !== "INSERT") return [...list];
  if (!isParsableSessionRow(event.row)) return [...list];
  const id = event.row!.id as string;
  let session: Session;
  try {
    session = toSession(event.row as unknown as SessionRow);
  } catch {
    return [...list];
  }
  const present = list.some((s) => s.id === id);
  return sortPendingSessions(
    present ? list.map((s) => (s.id === id ? session : s)) : [...list, session],
  );
}

/// Apply a batch of realtime events (oldest first) to a sessions list. Pure
/// and idempotent — re-applying the same events is a no-op — so the bounded
/// queue can be re-walked on every change without tracking a cursor (same
/// contract as `applyRecordingRealtimeEvents`).
export function applySessionRealtimeEvents(
  list: readonly Session[],
  events: readonly RealtimeSessionRowEvent[],
): Session[] {
  let next = [...list];
  for (const event of events) next = applySessionRealtimeEvent(next, event);
  return next;
}

/// Has every INSERT event in the queue already landed in `list`? The
/// useTrainingData fetch guard uses this to skip the whole-list refetch when
/// the bump was a session write the apply path already handled. An
/// un-applied event (a row that failed to parse) reads false and the
/// refetch reconciles.
export function sessionEventsAllApplied(
  events: readonly RealtimeSessionRowEvent[],
  list: readonly Session[],
): boolean {
  for (const event of events) {
    if (event.eventType !== "INSERT") return false;
    if (!isParsableSessionRow(event.row)) return false;
    const id = event.row!.id as string;
    if (!list.some((s) => s.id === id)) return false;
  }
  return true;
}
