import type { NewTindeqRecording } from "../types";

// The one queued-recording shape, shared by BOTH stores (#269): the IndexedDB
// main queue (`recordingDb.ts`) and the synchronous localStorage lane
// (`recordingQueue.ts`). It lives in its own module so neither store has to
// import the other just to name what it holds — an entry moves between them
// unchanged, which is what makes the sync lane drainable into the main store
// and the localStorage→IndexedDB migration a straight copy.

/// A recording queued for retry. `input.id` is a client-generated uuid,
/// supplied to insertRecording as the row's primary key — a retry of an
/// insert that actually landed server-side (but whose response the client
/// never saw, e.g. the session died mid-request) then collides on the
/// unique constraint (Postgres 23505) instead of creating a duplicate row.
/// `id` mirrors `input.id` for convenient local dedup/lookup — and is the
/// IndexedDB store's keyPath, which is what makes re-copying an entry the
/// migration already moved an idempotent overwrite rather than a duplicate.
export interface PendingRecording {
  id: string;
  queuedAt: string; // ISO — display + FIFO eviction order
  /// The session that captured it, when known. A drain only ever attempts
  /// entries matching the CURRENT user, so a stale queue can never attribute
  /// a rep to whoever happens to sign in next (solo-user app today, but
  /// cheap to get right).
  userId: string | null;
  input: NewTindeqRecording & { id: string };
}

/// Structural check applied to everything read back out of EITHER store — a
/// hand-edited localStorage blob or a record written by an older build must
/// read as "not a recording" rather than crash a drain.
export function isPendingRecording(v: unknown): v is PendingRecording {
  if (!v || typeof v !== "object") return false;
  const r = v as Record<string, unknown>;
  if (
    typeof r.id !== "string" ||
    typeof r.queuedAt !== "string" ||
    !(r.userId === null || typeof r.userId === "string") ||
    !r.input ||
    typeof r.input !== "object"
  ) {
    return false;
  }
  const input = r.input as Record<string, unknown>;
  return typeof input.id === "string" && Array.isArray(input.samples);
}

/// Approximate serialized size, used by both stores' byte budgets. JSON length
/// rather than a real byte count: it is an over/under of a few percent for
/// non-ASCII, and every budget it feeds has orders of magnitude of slack.
export function approxByteSize(queue: PendingRecording[]): number {
  return JSON.stringify(queue).length;
}

/// Oldest first, which is the order both stores' eviction and drain logic
/// assume. localStorage keeps insertion order for free; IndexedDB returns
/// records in KEY order (a uuid), so it has to be re-established on read.
export function byQueuedAt(a: PendingRecording, b: PendingRecording): number {
  if (a.queuedAt !== b.queuedAt) return a.queuedAt < b.queuedAt ? -1 : 1;
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}
