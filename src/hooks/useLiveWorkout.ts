import { useEffect, useState } from "react";
import { Capacitor } from "@capacitor/core";
import type { PluginListenerHandle } from "@capacitor/core";
import { SendLogAuthBridge } from "sendlog-auth-bridge";
import type { LiveWorkoutMessage } from "sendlog-auth-bridge";
import { supabase } from "../lib/supabase";
import { fetchLiveWorkout } from "../lib/repo";
import type { LiveWorkout } from "../types";

/// How long a heartbeat may go quiet before the workout is presumed dead
/// (watch upserts every ~5s; 30s of silence = app killed / walked away).
const STALE_MS = 30_000;

/// WatchConnectivity beat → LiveWorkout (epoch seconds → ISO strings). The
/// WC path has no workout_id; keep the previous row's id so correlation
/// survives (beats always follow the initial Supabase row in practice).
function messageToLive(
  msg: LiveWorkoutMessage,
  prev: LiveWorkout | null,
): LiveWorkout {
  const iso = (sec: number | undefined) =>
    sec !== undefined ? new Date(sec * 1000).toISOString() : null;
  return {
    workoutId: prev?.workoutId ?? "wc-live",
    status: msg.status,
    startedAt: iso(msg.started_at) ?? prev?.startedAt ?? new Date().toISOString(),
    hr: msg.hr ?? null,
    attemptCount: msg.attempt_count ?? 0,
    activeKcal: msg.active_kcal ?? null,
    elevationGainM: msg.elevation_gain_m ?? null,
    climbing: msg.climbing ?? false,
    climbingSince: iso(msg.climbing_since),
    restStartedAt: iso(msg.rest_started_at),
    restTargetS: msg.rest_target_s ?? null,
    updatedAt: iso(msg.updated_at) ?? new Date().toISOString(),
  };
}

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
    climbingSince: (row.climbing_since as string | null) ?? null,
    restStartedAt: (row.rest_started_at as string | null) ?? null,
    restTargetS: (row.rest_target_s as number | null) ?? null,
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

    // Bluetooth-fast path (native only): the watch also beats over
    // WatchConnectivity via the auth-bridge plugin — sub-second, no network.
    // Keep whichever source is newest; Supabase remains the fallback and the
    // only path for web-on-desktop.
    let wcHandle: PluginListenerHandle | null = null;
    if (Capacitor.isNativePlatform()) {
      void SendLogAuthBridge.addListener("liveWorkout", (msg) => {
        setRow((prev) => {
          const next = messageToLive(msg, prev);
          if (prev && new Date(prev.updatedAt).getTime() > new Date(next.updatedAt).getTime()) {
            return prev;
          }
          return next;
        });
      }).then((h) => {
        wcHandle = h;
      });
    }

    const interval = setInterval(() => setNow(Date.now()), 5_000);
    return () => {
      cancelled = true;
      clearInterval(interval);
      void supabase.removeChannel(channel);
      void wcHandle?.remove();
    };
  }, [userId]);

  if (!row || row.status !== "live") return null;
  if (now - new Date(row.updatedAt).getTime() > STALE_MS) return null;
  return row;
}
