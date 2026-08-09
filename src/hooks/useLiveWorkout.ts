import { useEffect, useRef, useState } from "react";
import { Capacitor } from "@capacitor/core";
import { SendLogAuthBridge } from "sendlog-auth-bridge";
import { supabase } from "../lib/supabase";
import { fetchLiveWorkout } from "../lib/repo";
import type { LiveWorkout } from "../types";
import { subscribePluginListener } from "./pluginListener";
import {
  messageToLive,
  reduceLiveWorkout,
  rowToLive,
  visibleLiveWorkout,
  type HrLog,
  type LiveHrPoint,
  type LiveWorkoutMirrorState,
  type LiveWorkoutSource,
} from "../lib/liveWorkoutMirror";

export type { LiveHrPoint };

export type LiveWorkoutSyncState = "watch-direct" | "server-fallback";

export interface LiveWorkoutMirrorResult {
  row: LiveWorkout | null;
  hrLog: LiveHrPoint[];
  syncState: LiveWorkoutSyncState;
}

/// The user's in-progress watch workout, mirrored live (SL-41): one initial
/// fetch plus a dedicated realtime channel that reads row payloads directly.
/// Deliberately NOT part of RealtimeVersionProvider — a 5s heartbeat through
/// the global version counter would refetch every card in the app every 5s.
///
/// The two transports reduce through one ref-owned state machine (#521): the
/// WatchConnectivity beat is immediate, while Supabase remains the durable
/// fallback. Duplicate/out-of-order packets and late live packets after End
/// never reach React state.
export function useLiveWorkout(
  userId: string,
): [LiveWorkout | null, LiveHrPoint[], LiveWorkoutSyncState] {
  const [row, setRow] = useState<LiveWorkout | null>(null);
  const [hrLog, setHrLog] = useState<HrLog>({ id: "", pts: [] });
  const [syncState, setSyncState] = useState<LiveWorkoutSyncState>("server-fallback");
  const [now, setNow] = useState(() => Date.now());
  const mirrorRef = useRef<LiveWorkoutMirrorState>({
    row: null,
    hrLog: { id: "", pts: [] },
    source: "server-fallback",
  });

  useEffect(() => {
    let cancelled = false;

    function ingest(next: LiveWorkout, source: LiveWorkoutSource) {
      if (cancelled) return;
      const reduced = reduceLiveWorkout(mirrorRef.current, next, source);
      if (!reduced.accepted) return;
      mirrorRef.current = reduced.state;
      setRow(reduced.state.row);
      setHrLog(reduced.state.hrLog);
      setSyncState(reduced.state.source);
    }

    fetchLiveWorkout()
      .then((next) => {
        if (cancelled || !next) return;
        ingest(next, "server-fallback");
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
            ingest(rowToLive(payload.new), "server-fallback");
          }
        },
      )
      .subscribe();

    // Bluetooth-fast path (native only): the watch also beats over
    // WatchConnectivity via the auth-bridge plugin — sub-second, no network.
    // Supabase remains the durable fallback and the only path on desktop.
    //
    // #485 F7: `subscribePluginListener` removes a handle even when its async
    // registration resolves after this effect has cleaned up.
    const unsubscribeWc = Capacitor.isNativePlatform()
      ? subscribePluginListener(() =>
          SendLogAuthBridge.addListener("liveWorkout", (msg) => {
            const previous = mirrorRef.current.row;
            ingest(messageToLive(msg, previous), "watch-direct");
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

  const [visible, series] = visibleLiveWorkout(row, hrLog, now);
  return [visible, series, syncState];
}
