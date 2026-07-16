import { useEffect, useState } from "react";
import { supabase } from "../lib/supabase";
import { fetchLiveWorkout } from "../lib/repo";
import type { LiveWorkout } from "../types";

/// How long a heartbeat may go quiet before the workout is presumed dead
/// (watch upserts every ~5s; 30s of silence = app killed / walked away).
const STALE_MS = 30_000;

function rowToLive(row: Record<string, unknown>): LiveWorkout {
  return {
    workoutId: row.workout_id as string,
    status: row.status as LiveWorkout["status"],
    startedAt: row.started_at as string,
    hr: row.hr as number | null,
    attemptCount: row.attempt_count as number,
    activeKcal: row.active_kcal as number | null,
    elevationGainM: row.elevation_gain_m as number | null,
    climbing: row.climbing as boolean,
    updatedAt: row.updated_at as string,
  };
}

/// The user's in-progress watch workout, mirrored live (SL-41): one initial
/// fetch plus a dedicated realtime channel that reads row payloads directly.
/// Deliberately NOT part of RealtimeVersionProvider — a 5s heartbeat through
/// the global version counter would refetch every card in the app every 5s.
/// Returns null when there's no workout, it ended, or the heartbeat went
/// stale.
export function useLiveWorkout(userId: string): LiveWorkout | null {
  const [row, setRow] = useState<LiveWorkout | null>(null);
  // Re-evaluate staleness on a timer even with no new events.
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    let cancelled = false;
    fetchLiveWorkout()
      .then((r) => {
        if (!cancelled) setRow(r);
      })
      .catch(() => {});

    const channel = supabase
      .channel(`live-workout-${userId}`)
      .on(
        "postgres_changes",
        {
          event: "*",
          schema: "public",
          table: "live_workouts",
          filter: `user_id=eq.${userId}`,
        },
        (payload) => {
          if (payload.new && "workout_id" in payload.new) {
            setRow(rowToLive(payload.new));
          }
        },
      )
      .subscribe();

    const interval = setInterval(() => setNow(Date.now()), 5_000);
    return () => {
      cancelled = true;
      clearInterval(interval);
      void supabase.removeChannel(channel);
    };
  }, [userId]);

  if (!row || row.status !== "live") return null;
  if (now - new Date(row.updatedAt).getTime() > STALE_MS) return null;
  return row;
}
