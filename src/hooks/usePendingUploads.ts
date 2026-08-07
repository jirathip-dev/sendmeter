import { useEffect, useState } from "react";
import { Capacitor } from "@capacitor/core";
import { App as CapacitorApp } from "@capacitor/app";
import { subscribePendingUploads, type PendingUploadsBreakdown } from "../lib/pendingUploads";
import { pendingRecordingsBreakdown } from "../lib/recordingQueue";

/// #269: the offline recording queue's depth, for the ambient indicators.
/// `null` until the first read completes — callers must not treat it as an
/// empty queue. History intentionally stays quiet until there is an actionable
/// pending/stuck count; diagnostic surfaces can use `pendingUploadsLine` when
/// they need to distinguish unknown from empty.
///
/// #484: split into `{pending, stuck}` (see `pendingRecordingsBreakdown`) so
/// a recording the server keeps rejecting renders as its own honest state
/// rather than either counting as "will sync" or going silent — #475 F1 on
/// the watch was a BLOCKER for a quarantine count with no reader anywhere.
///
/// #484 F5: scoped to `userId` — see `pendingRecordingsCount` for why an
/// unscoped count is a real bug, not just a cosmetic one (it gets read back
/// as "will sync").
///
/// Re-reads on four signals, because the queue changes from places this
/// component can't see: the module-level notification (something queued or
/// drained in this tab), app foreground (a drain may have run while
/// backgrounded, and on native the WebView can be suspended mid-drain), a
/// change of account, and mount.
/// A `refresh()` that only ever applies the LATEST in-flight read to
/// `onValue` — #485 F6: `refresh` fires once per signal (mount, the
/// module-level notification, foreground) with no sequencing between them,
/// so a slow earlier call resolving AFTER a faster later one used to
/// overwrite the fresh value with a stale one. `active` additionally covers
/// a caller that has since unmounted, same as `subscribeToWatchInfo`'s
/// `active` flag in `useWatchInfo.ts` (the same shape, extracted here so the
/// ordering property is directly testable without a React renderer, which
/// this repo has none of for hooks).
export function makeSequencedRefresher<T>(
  load: () => Promise<T>,
  onValue: (v: T) => void,
): { refresh: () => void; stop: () => void } {
  let active = true;
  let latestRequest = 0;
  return {
    refresh: () => {
      if (!active) return;
      const request = ++latestRequest;
      // setState only ever inside the async callback — never synchronously in
      // an effect body (react-compiler lint).
      void load().then((v) => {
        if (active && request === latestRequest) onValue(v);
      });
    },
    stop: () => {
      active = false;
    },
  };
}

export function usePendingUploads(userId: string): PendingUploadsBreakdown | null {
  const [breakdown, setBreakdown] = useState<PendingUploadsBreakdown | null>(null);

  useEffect(() => {
    const { refresh, stop } = makeSequencedRefresher(
      () => pendingRecordingsBreakdown(userId),
      setBreakdown,
    );
    refresh();
    const unsubscribe = subscribePendingUploads(refresh);
    if (!Capacitor.isNativePlatform()) {
      // The web equivalent of a foreground: a tab that was hidden while a
      // drain ran comes back with a stale number otherwise.
      const onVisible = () => {
        if (document.visibilityState === "visible") refresh();
      };
      document.addEventListener("visibilitychange", onVisible);
      return () => {
        stop();
        unsubscribe();
        document.removeEventListener("visibilitychange", onVisible);
      };
    }
    const sub = CapacitorApp.addListener("appStateChange", ({ isActive }) => {
      if (isActive) refresh();
    });
    return () => {
      stop();
      unsubscribe();
      void sub.then((h) => h.remove());
    };
  }, [userId]);

  return breakdown;
}
