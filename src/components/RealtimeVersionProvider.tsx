import { useCallback, useEffect, useState } from "react";
import type { ReactNode } from "react";
import { supabase } from "../lib/supabase";
import { noteRealtimeRecordingReceipt } from "../lib/forceLatency";
import type { RealtimeRecordingRowEvent } from "../lib/realtimeRecordingApply";
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

/// #613: narrow a postgres_changes payload down to what the apply path reads,
/// so RealtimeVersionProvider never leaks raw payload shapes into consumers.
function toRealtimeRecordingEvent(payload: {
  eventType: string;
  new: unknown;
  old: unknown;
}): RealtimeRecordingRowEvent {
  const asRecord = (v: unknown): Record<string, unknown> | null =>
    v && typeof v === "object" && !Array.isArray(v)
      ? (v as Record<string, unknown>)
      : null;
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
    row: payload.eventType === "DELETE" ? null : asRecord(payload.new),
    oldRow:
      payload.eventType === "INSERT" ? null : asRecord(payload.old ?? payload.new),
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
              const event = toRealtimeRecordingEvent(payload);
              const next = [...s.recordingEvents, event];
              const overflowed =
                s.recordingEventsOverflowed ||
                next.length > MAX_RECORDING_EVENTS;
              return {
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
