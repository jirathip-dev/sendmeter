import {
  FLUSH_MARKER_KEY,
  getAuthDiagnosticEvents,
  getAuthEventStore,
  type AuthDiagnosticEvent,
  type AuthEventStorage,
} from "./authDiagnostics";

/// Issue #202: an on-device ring only helps if someone reads the device. The
/// logout happens overnight and the evidence is needed the next morning, so
/// the ring is pushed to Supabase (`auth_events`) on the next successful
/// sign-in — the one moment we're guaranteed a valid token and an authenticated
/// user id.
///
/// Deliberately NOT on the auth critical path: the caller fires this
/// fire-and-forget, and every failure mode here resolves to a result value
/// instead of throwing. A diagnostics upload must never be able to break a
/// sign-in.
export interface AuthEventRow {
  user_id: string;
  reason: string;
  source: string | null;
  auth_event: string | null;
  occurrences: number;
  first_at: string;
  last_at: string;
  last_good_at: string | null;
  last_good_expires_at: string | null;
  app_build: string | null;
  event_store: string | null;
}

export type FlushResult = "skipped" | "flushed" | "empty" | "failed";

/// `(user_id, reason, first_at)` is the row identity — it matches the unique
/// index the migration creates, so re-sending an entry whose count has grown
/// UPDATES the row instead of inserting a second one.
function rowKey(row: AuthEventRow): string {
  return `${row.reason}|${row.first_at}`;
}

/// Maps ring entries to rows, oldest first, deduped on the conflict key.
/// A payload containing the same key twice would make Postgres fail the whole
/// upsert ("cannot affect row a second time"), which would lose the entire
/// batch over a collision in the metadata we don't key on.
export function authEventRows(
  userId: string,
  events: readonly AuthDiagnosticEvent[],
): AuthEventRow[] {
  const byKey = new Map<string, AuthEventRow>();
  for (const e of events) {
    const row: AuthEventRow = {
      user_id: userId,
      reason: e.reason,
      source: e.source ?? null,
      auth_event: e.authEvent ?? null,
      occurrences: e.count,
      first_at: e.firstAt,
      last_at: e.lastAt,
      last_good_at: e.lastGoodAt ?? null,
      last_good_expires_at: e.lastGoodExpiresAt ?? null,
      app_build: e.build ?? null,
      event_store: e.store ?? null,
    };
    const existing = byKey.get(rowKey(row));
    // Keep the fuller record when two entries collide on the key.
    if (!existing || existing.occurrences < row.occurrences) {
      byKey.set(rowKey(row), row);
    }
  }
  return [...byKey.values()].sort((a, b) => a.first_at.localeCompare(b.first_at));
}

/// Idempotency layer 1 (client): a stable fingerprint of what was last sent,
/// so a relaunch with an unchanged ring performs no network call at all.
/// Layer 2 is the unique index + upsert, which keeps things correct even if
/// this marker is lost.
export function flushSignature(rows: readonly AuthEventRow[]): string {
  return JSON.stringify(
    rows.map((r) => [r.reason, r.first_at, r.last_at, r.occurrences]),
  );
}

export async function flushAuthEvents(
  userId: string,
  opts: {
    events?: readonly AuthDiagnosticEvent[];
    storage?: AuthEventStorage | null;
    upsert?: (rows: AuthEventRow[]) => Promise<void>;
  },
): Promise<FlushResult> {
  const upsert = opts.upsert;
  if (!upsert) return "failed";
  try {
    const storage =
      opts.storage === undefined ? getAuthEventStore() : opts.storage;
    const events = opts.events ?? getAuthDiagnosticEvents();
    const rows = authEventRows(userId, events);
    if (rows.length === 0) return "empty";

    const signature = `${userId}:${flushSignature(rows)}`;
    let marker: string | null = null;
    try {
      marker = storage?.getItem(FLUSH_MARKER_KEY) ?? null;
    } catch {
      marker = null;
    }
    if (marker === signature) return "skipped";

    await upsert(rows);

    try {
      storage?.setItem(FLUSH_MARKER_KEY, signature);
    } catch {
      // Losing the marker only costs a redundant upsert next launch; the
      // unique index keeps that from duplicating rows.
    }
    return "flushed";
  } catch {
    // Network down, RLS surprise, table not yet migrated — none of which may
    // touch the sign-in that triggered this.
    return "failed";
  }
}
