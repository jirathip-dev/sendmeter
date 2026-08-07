import { useEffect, useRef, useState } from "react";
import { Capacitor } from "@capacitor/core";
import { SendLogAuthBridge } from "sendlog-auth-bridge";
import { supabase } from "../lib/supabase";
import { fetchLiveWorkout } from "../lib/repo";
import type { LiveWorkout } from "../types";
import { subscribePluginListener } from "./pluginListener";
import {
  appendHrPoint,
  messageToLive,
  preferFresher,
  rowToLive,
  visibleLiveWorkout,
  type HrLog,
  type LiveHrPoint,
} from "../lib/liveWorkoutMirror";

export type { LiveHrPoint };

/// The user's in-progress watch workout, mirrored live (SL-41): one initial
/// fetch plus a dedicated realtime channel that reads row payloads directly.
/// Deliberately NOT part of RealtimeVersionProvider — a 5s heartbeat through
/// the global version counter would refetch every card in the app every 5s.
/// Returns [null, series] when there's no workout, it ended, or the heartbeat
/// went stale.
export function useLiveWorkout(
  userId: string,
): [LiveWorkout | null, LiveHrPoint[]] {
  const [row, setRow] = useState<LiveWorkout | null>(null);
  // Mirror of `row` for the event callbacks — lets the WC listener compare
  // freshness without doing side effects inside a setState updater.
  const rowRef = useRef<LiveWorkout | null>(null);
  // HR series keyed by workout id so a new workout starts a fresh chart.
  // Appended only inside async callbacks (react-compiler: no sync setState
  // in effect bodies).
  const [hrLog, setHrLog] = useState<HrLog>({ id: "", pts: [] });
  // Re-evaluate staleness on a timer even with no new events.
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    let cancelled = false;

    function ingest(next: LiveWorkout) {
      setHrLog((prev) => appendHrPoint(prev, next));
    }

    fetchLiveWorkout()
      .then((r) => {
        if (cancelled) return;
        rowRef.current = r;
        setRow(r);
        if (r) ingest(r);
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
            const next = rowToLive(payload.new);
            rowRef.current = next;
            setRow(next);
            ingest(next);
          }
        },
      )
      .subscribe();

    // Bluetooth-fast path (native only): the watch also beats over
    // WatchConnectivity via the auth-bridge plugin — sub-second, no network.
    // Keep whichever source is newest; Supabase remains the fallback and the
    // only path for web-on-desktop.
    //
    // #485 F7: `subscribePluginListener` (see its doc comment) so a handle
    // that resolves after this effect has already cleaned up still gets
    // removed instead of leaking.
    const unsubscribeWc = Capacitor.isNativePlatform()
      ? subscribePluginListener(() =>
          SendLogAuthBridge.addListener("liveWorkout", (msg) => {
            const prev = rowRef.current;
            const next = preferFresher(prev, messageToLive(msg, prev));
            if (next === prev) return; // a fresher supabase row already landed
            rowRef.current = next;
            setRow(next);
            ingest(next);
          }),
        )
      : null;

    const interval = setInterval(() => setNow(Date.now()), 5_000);
    return () => {
      cancelled = true;
      clearInterval(interval);
      void supabase.removeChannel(channel);
      unsubscribeWc?.();
    };
  }, [userId]);

  return visibleLiveWorkout(row, hrLog, now);
}
