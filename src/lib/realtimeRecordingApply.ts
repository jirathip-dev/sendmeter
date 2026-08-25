import type { TindeqRecordingMeta } from "../types";
import { toRecording } from "./repo/tindeq";

/// One `tindeq_recordings` postgres_changes event, narrowed to what the apply
/// path needs. `row` is the payload's `new` (INSERT/UPDATE), `oldRow` its
/// `old` (UPDATE/DELETE). Produced by RealtimeVersionProvider, applied by
/// ForceView — the pure logic lives here so the reconciliation is testable
/// without React or a live realtime channel.
export interface RealtimeRecordingRowEvent {
  eventType: "INSERT" | "UPDATE" | "DELETE";
  row: Record<string, unknown> | null;
  oldRow: Record<string, unknown> | null;
}

type RecordingRow = Parameters<typeof toRecording>[0];

function rowId(row: Record<string, unknown> | null): string {
  if (!row) return "";
  const id = row.id;
  return typeof id === "string" ? id : "";
}

/// `toRecording` is tolerant (missing fields parse to undefined, not a throw),
/// so a malformed realtime row would otherwise become a bogus meta. Require the
/// fields a real row always has before letting it through; anything else is
/// skipped and the refetch guard reconciles via a full fetch.
function isParsableRecordingRow(row: Record<string, unknown> | null): boolean {
  if (!row) return false;
  return (
    typeof row.id === "string" &&
    typeof row.recorded_at === "string" &&
    typeof row.duration_ms === "number" &&
    typeof row.tag === "string"
  );
}

/// Apply ONE realtime event to a recordings list, by id. Idempotent: an
/// INSERT for an already-present id replaces rather than duplicates, an UPDATE
/// for an absent id prepends (a row we never loaded), and a DELETE for an
/// absent id is a no-op. A row that fails to parse (schema drift) is skipped —
/// the caller's refetch guard sees the event as un-applied and falls back to a
/// full reconciliation.
function applyRecordingRealtimeEvent(
  list: readonly TindeqRecordingMeta[],
  event: RealtimeRecordingRowEvent,
): TindeqRecordingMeta[] {
  if (event.eventType === "DELETE") {
    const id = rowId(event.oldRow);
    return id ? list.filter((r) => r.id !== id) : [...list];
  }
  if (event.eventType === "UPDATE" && event.row?.deleted_at != null) {
    // Soft delete: the row still exists server-side with deleted_at set.
    const id = rowId(event.row);
    return id ? list.filter((r) => r.id !== id) : [...list];
  }
  if (!isParsableRecordingRow(event.row)) return [...list];
  const id = rowId(event.row);
  if (!id) return [...list];
  let meta: TindeqRecordingMeta;
  try {
    meta = toRecording(event.row as RecordingRow);
  } catch {
    return [...list];
  }
  const present = list.some((r) => r.id === id);
  return present
    ? list.map((r) => (r.id === id ? meta : r))
    : [meta, ...list];
}

/// Apply a batch of realtime events (oldest first) to a recordings list. Pure
/// and idempotent — re-applying the same events is a no-op — so the bounded
/// queue can be re-walked on every change without tracking a cursor.
export function applyRecordingRealtimeEvents(
  list: readonly TindeqRecordingMeta[],
  events: readonly RealtimeRecordingRowEvent[],
): TindeqRecordingMeta[] {
  let next = [...list];
  for (const event of events) next = applyRecordingRealtimeEvent(next, event);
  return next;
}

/// Deep-equality for one recording meta, with null and undefined treated as
/// equal — the DB stores null and `toRecording`/`pendingRecordingMeta` can
/// read the same absence as either, so "no value" must not count as a change.
/// Objects are compared key-order-independently and array/object fields
/// (`cadenceMarkers`, `setMetrics`) recursively, so a real cross-device edit
/// on ANY field — not just the scalar ones — reads as a change.
function recordingMetaEqual(a: TindeqRecordingMeta, b: TindeqRecordingMeta): boolean {
  return deepEqual(a, b);
}

function deepEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (a == null || b == null) return a == null && b == null;
  if (Array.isArray(a) && Array.isArray(b)) {
    return a.length === b.length && a.every((v, i) => deepEqual(v, b[i]));
  }
  if (typeof a === "object" && typeof b === "object") {
    const ak = Object.keys(a as object).sort();
    const bk = Object.keys(b as object).sort();
    if (ak.length !== bk.length || ak.some((k, i) => k !== bk[i])) return false;
    const ar = a as Record<string, unknown>;
    const br = b as Record<string, unknown>;
    return ak.every((k) => deepEqual(ar[k], br[k]));
  }
  return false;
}

/// Are two recordings lists the same content, position for position? The
/// ForceView refetch guard uses this to skip a whole-list refetch that changed
/// nothing — comparing every field, so an edit to any field (e.g. a
/// duration_ms or zone change that arrived via a dropped realtime event) is
/// still applied rather than discarded as "unchanged".
export function recordingListsEqual(
  a: readonly TindeqRecordingMeta[],
  b: readonly TindeqRecordingMeta[],
): boolean {
  return (
    a.length === b.length &&
    a.every((r, i) => recordingMetaEqual(r, b[i]!))
  );
}

/// Has every event in the queue already landed in `list`? The ForceView fetch
/// guard uses this to skip the whole-list refetch when the bump was its own (or
/// any) recording write the apply path already handled — a recording write must
/// not trigger a coarse refetch. An un-applied event (a row we never loaded, or
/// one that failed to parse) reads false and the refetch reconciles.
export function recordingEventsAllApplied(
  events: readonly RealtimeRecordingRowEvent[],
  list: readonly TindeqRecordingMeta[],
): boolean {
  for (const event of events) {
    // A soft-delete UPDATE applies by REMOVING the row, exactly like a DELETE.
    const isSoftDelete =
      event.eventType === "UPDATE" && event.row?.deleted_at != null;
    if (event.eventType === "DELETE" || isSoftDelete) {
      const id = isSoftDelete ? rowId(event.row) : rowId(event.oldRow);
      if (id && list.some((r) => r.id === id)) return false;
      continue;
    }
    const id = rowId(event.row);
    if (!id) return false;
    if (!list.some((r) => r.id === id)) return false;
  }
  return true;
}
