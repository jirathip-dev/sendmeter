import { useCallback, useEffect, useState } from "react";
import type { ReactNode } from "react";
import { supabase } from "../lib/supabase";
import { noteRealtimeRecordingReceipt } from "../lib/forceLatency";
import type { RealtimeRecordingRowEvent } from "../lib/realtimeRecordingApply";
import type { RealtimeSessionRowEvent } from "../lib/sessionRealtimeApply";
import {
  RealtimeBumpContext,
  RealtimeVersionContext,
  type RealtimeVersionState,
} from "../hooks/useRealtimeVersion";

// Every table a watch write can touch. Kept in sync with the
// `alter publication supabase_realtime add table ...` migration.
const WATCHED_TABLES = [
  "sessions",
  "tindeq_recordings",
  "climb_workouts",
  "climb_attempts",
  "health_metrics",
] as const;

/// Bounded queue of `tindeq_recordings` realtime events. Large enough that a
/// fast rep burst never overflows; if it ever does, `recordingEventsOverflowed`
/// forces the ForceView refetch guard back to a full reconciliation for the
/// session (safe degradation, never silent loss).
const MAX_RECORDING_EVENTS = 128;

/// Bounded queue of `sessions` realtime events (#615). A workout's write
/// burst is a handful of rows; the cap exists so a pathological flood can
/// never grow app-root context state without bound. Overflow flips
/// `sessionEventsOverflowed`, which forces the training-data refetch guard
/// back to a full reconciliation (the `version` bump also always fires).
const MAX_SESSION_EVENTS = 32;

/// #613: narrow a postgres_changes payload down to what the apply path reads,
/// so RealtimeVersionProvider never leaks raw payload shapes into consumers.
///
/// The full row is stripped to the columns the apply path actually maps,
/// plus `deleted_at` (the soft-delete check). Everything else — notably
/// `samples` (the jsonb sample stream, tens of KB per rep), `user_id`,
/// `created_at`, `updated_at` — is dropped BEFORE enqueueing, because the
/// bounded queues (up to 128 / 32 events) live in app-root context state
/// for the whole session and nothing in the apply paths ever reads them.
const STRIPPED_ROW_COLUMNS = new Set([
  "samples",
  "user_id",
  "created_at",
  "updated_at",
]);

function toRealtimeRowEvent(payload: {
  eventType: string;
  new: unknown;
  old: unknown;
}): RealtimeRecordingRowEvent & RealtimeSessionRowEvent {
  const asRecord = (v: unknown): Record<string, unknown> | null =>
    v && typeof v === "object" && !Array.isArray(v)
      ? (v as Record<string, unknown>)
      : null;
  const strip = (v: Record<string, unknown> | null) => {
    if (!v) return null;
    const out: Record<string, unknown> = {};
    for (const [k, val] of Object.entries(v)) {
      if (!STRIPPED_ROW_COLUMNS.has(k)) out[k] = val;
    }
    return out;
  };
  // Preserve the real event type — the apply path distinguishes a soft-delete
  // UPDATE (deleted_at set) from an INSERT by `eventType === "UPDATE"`.
  const eventType =
    payload.eventType === "UPDATE"
      ? "UPDATE"
      : payload.eventType === "DELETE"
        ? "DELETE"
        : "INSERT";
  return {
    eventType,
    row: payload.eventType === "DELETE" ? null : strip(asRecord(payload.new)),
    oldRow:
      payload.eventType === "INSERT"
        ? null
        : strip(asRecord(payload.old ?? payload.new)),
  };
}

/// Subscribes once (at the authed-app root) to postgres_changes for every
/// table the watch writes to, scoped to this user by RLS + the filter.
/// A workout/recording/health row saved from the watch shows up live on the
/// web and iOS app without a manual reload.
///
/// #613: `tindeq_recordings` events additionally ride along as a bounded queue
/// (see `RealtimeVersionState`), so the Force view can apply a recording write
/// directly instead of treating every bump as a whole-list refetch. The
/// generic `version` bump still fires for the table like any other — the
/// payload is an optimization, not the only signal.
export default function RealtimeVersionProvider({
  userId,
  children,
}: {
  userId: string;
  children: ReactNode;
}) {
  const [state, setState] = useState<RealtimeVersionState>({
    version: 0,
    recordingEvents: [],
    recordingEventsOverflowed: false,
    sessionEvents: [],
    sessionEventsOverflowed: false,
  });
  const bump = useCallback(
    () => setState((s) => ({ ...s, version: s.version + 1 })),
    [],
  );

  useEffect(() => {
    const channel = supabase.channel(`user-data-${userId}`);
    for (const table of WATCHED_TABLES) {
      if (table === "tindeq_recordings") {
        channel.on(
          "postgres_changes",
          { event: "*", schema: "public", table, filter: `user_id=eq.${userId}` },
          (payload) => {
            // #613: time the echo of our own writes (forceLatency.ts).
            noteRealtimeRecordingReceipt();
            setState((s) => {
              const event = toRealtimeRowEvent(payload);
              const next = [...s.recordingEvents, event];
              const overflowed =
                s.recordingEventsOverflowed ||
                next.length > MAX_RECORDING_EVENTS;
              return {
                ...s,
                version: s.version + 1,
                recordingEvents: overflowed
                  ? next.slice(-MAX_RECORDING_EVENTS)
                  : next,
                recordingEventsOverflowed: overflowed,
              };
            });
          },
        );
        continue;
      }
      if (table === "sessions") {
        // #615: sessions events ride along as a bounded queue (same shape as
        // the recording-events optimization) so useTrainingData can reconcile
        // a pending workout by id directly from the payload instead of
        // waiting on the coarse refetch. The generic `version` bump still
        // fires for the table like any other — the payload is an
        // optimization, not the only signal.
        channel.on(
          "postgres_changes",
          { event: "*", schema: "public", table, filter: `user_id=eq.${userId}` },
          (payload) => {
            setState((s) => {
              const event = toRealtimeRowEvent(payload);
              const next = [...s.sessionEvents, event];
              const overflowed =
                s.sessionEventsOverflowed ||
                next.length > MAX_SESSION_EVENTS;
              return {
                ...s,
                version: s.version + 1,
                sessionEvents: overflowed
                  ? next.slice(-MAX_SESSION_EVENTS)
                  : next,
                sessionEventsOverflowed: overflowed,
              };
            });
          },
        );
        continue;
      }
      channel.on(
        "postgres_changes",
        { event: "*", schema: "public", table, filter: `user_id=eq.${userId}` },
        () => setState((s) => ({ ...s, version: s.version + 1 })),
      );
    }
    channel.subscribe();
    return () => {
      void supabase.removeChannel(channel);
    };
  }, [userId]);

  return (
    <RealtimeVersionContext.Provider value={state}>
      <RealtimeBumpContext.Provider value={bump}>
        {children}
      </RealtimeBumpContext.Provider>
    </RealtimeVersionContext.Provider>
  );
}
