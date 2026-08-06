import { useEffect, useState } from "react";
import { Capacitor } from "@capacitor/core";
import { App as CapacitorApp } from "@capacitor/app";
import { subscribePendingUploads } from "../lib/pendingUploads";
import { pendingRecordingsCount } from "../lib/recordingQueue";

/// #269: the offline recording queue's depth, for the ambient indicators.
/// `null` until the first read completes — callers must not treat it as an
/// empty queue. History intentionally stays quiet until there is an actionable
/// pending count; diagnostic surfaces can use `pendingUploadsLine` when they
/// need to distinguish unknown from empty.
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
export function usePendingUploads(userId: string): number | null {
  const [count, setCount] = useState<number | null>(null);

  useEffect(() => {
    let alive = true;
    function refresh() {
      // setState only ever inside the async callback — never synchronously in
      // an effect body (react-compiler lint).
      void pendingRecordingsCount(userId).then((n) => {
        if (alive) setCount(n);
      });
    }
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
        alive = false;
        unsubscribe();
        document.removeEventListener("visibilitychange", onVisible);
      };
    }
    const sub = CapacitorApp.addListener("appStateChange", ({ isActive }) => {
      if (isActive) refresh();
    });
    return () => {
      alive = false;
      unsubscribe();
      void sub.then((h) => h.remove());
    };
  }, [userId]);

  return count;
}
