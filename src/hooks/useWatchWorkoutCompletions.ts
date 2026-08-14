import { useEffect, useRef } from "react";
import { App as CapacitorApp } from "@capacitor/app";
import { Capacitor } from "@capacitor/core";
import type { PluginListenerHandle } from "@capacitor/core";
import { SendLogAuthBridge } from "sendlog-auth-bridge";
import type { WorkoutCompletedMessage } from "sendlog-auth-bridge";
import {
  acceptsPacketOwner,
  hasAccountChangedSincePersisted,
  recordStampedPacketAccepted,
} from "../lib/liveMirrorOwnership";
import {
  pendingSessionFromWatchMessage,
  type PendingWorkout,
} from "../lib/pendingWorkouts";
import { subscribePluginListener } from "./pluginListener";

const IS_NATIVE = Capacitor.isNativePlatform();

/// #615: the watch's `workoutCompleted` notification — sent after its save
/// bundle is durably queued on the watch. The phone renders the completed
/// workout as a PENDING session immediately (supabase stays authoritative;
/// realtime/server data reconciles by session id). Native only, like the
/// live-workout mirror. The plugin ALSO stores notifications that arrived
/// while the WebView was suspended; this hook drains them on mount and on
/// every foreground, so a workout finished while the phone was in a pocket
/// still renders as pending instead of being lost.
///
/// The same #530 ownership boundary as the live mirrors applies: a packet
/// stamped for a different account is rejected (the watch may still be
/// relaying a run started under a previous account after the phone
/// switched), and an unstamped packet (pre-#530 build) is trusted only
/// while this mirror has never lived through an account transition.
export function useWatchWorkoutCompletions(
  userId: string,
  onCompleted: (pending: PendingWorkout) => void,
  /// #615 F5: called with the ids of the completions a DRAIN produced (a
  /// stored notification replayed on mount/foreground — its realtime INSERT
  /// was missed while the WebView was suspended, so the pending row would
  /// otherwise never reconcile). The receiver fetches them by id and
  /// reconciles; live deliveries skip this because their INSERT is expected
  /// on the realtime channel.
  onDrained?: (ids: string[]) => void,
): void {
  // The account the CURRENT render belongs to — the listener closure below
  // must read the account at packet time, not the one captured at mount
  // (an account switch mid-session must reject the old run's late packet).
  const activeUserIdRef = useRef(userId);
  const effectUserId = userId;
  useEffect(() => {
    activeUserIdRef.current = userId;
  }, [userId]);
  const hasHadAccountTransitionRef = useRef(hasAccountChangedSincePersisted(userId));

  useEffect(() => {
    if (!IS_NATIVE) return;
    let cancelled = false;

    // The pending row when the packet was accepted (and registered), null
    // otherwise — the drain uses it to know which ids may now need a
    // server-side reconcile.
    const accept = (msg: WorkoutCompletedMessage): PendingWorkout | null => {
      if (cancelled || activeUserIdRef.current !== effectUserId) return null;
      const activeUserId = activeUserIdRef.current;
      if (!acceptsPacketOwner(msg.account_user_id, activeUserId, hasHadAccountTransitionRef.current)) {
        return null;
      }
      if (msg.account_user_id !== undefined) {
        // A genuinely STAMPED acceptance is positive evidence this watch has
        // caught up to the current account — same rule as the live mirrors.
        hasHadAccountTransitionRef.current = false;
        recordStampedPacketAccepted(activeUserId);
      }
      const pending = pendingSessionFromWatchMessage(msg, activeUserId);
      if (pending) onCompleted(pending);
      return pending;
    };

    // #485 F7: remove the handle whenever its registration resolves, even if
    // this effect already cleaned up.
    const unsubscribeWc = subscribePluginListener(() =>
      SendLogAuthBridge.addListener("workoutCompleted", accept),
    );

    // Replay notifications that arrived while the WebView was suspended.
    const drain = async () => {
      try {
        const { completions } = await SendLogAuthBridge.getPendingWorkoutCompletions();
        if (cancelled) return;
        const drainedIds: string[] = [];
        for (const msg of completions) {
          const pending = accept(msg);
          if (pending) drainedIds.push(pending.id);
        }
        // #615 F5: a completion that waited out a suspension had its
        // realtime INSERT missed — register the pending row AND reconcile
        // against the server by id, or it would sit "syncing" until an
        // unrelated event refetched.
        if (drainedIds.length > 0) onDrained?.(drainedIds);
      } catch {
        // Plugin older than this build — nothing to drain.
      }
    };
    void drain();
    let appSub: Promise<PluginListenerHandle> | null = null;
    if (Capacitor.isNativePlatform()) {
      appSub = CapacitorApp.addListener("appStateChange", ({ isActive }) => {
        if (isActive) void drain();
      });
    }
    return () => {
      cancelled = true;
      unsubscribeWc();
      void appSub?.then((h) => h.remove()).catch(() => {});
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [userId, onCompleted, onDrained]);
}
