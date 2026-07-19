import { useEffect } from "react";

/// Hold a screen wake lock while `active` — keeps the phone from sleeping
/// mid-recording (users with a short auto-lock kept losing the live gauge).
/// Uses the Web Wake Lock API (iOS 16.4+ / WKWebView); a no-op where it isn't
/// supported. Re-acquires when the app returns to the foreground, since iOS
/// auto-releases the lock whenever the page is hidden.
export function useWakeLock(active: boolean): void {
  useEffect(() => {
    if (!active || typeof navigator === "undefined") return;
    const wl = navigator.wakeLock;
    if (!wl) return;

    let sentinel: WakeLockSentinel | null = null;
    let cancelled = false;

    const acquire = () => {
      if (sentinel || cancelled) return;
      wl.request("screen")
        .then((s) => {
          if (cancelled) {
            void s.release().catch(() => {});
            return;
          }
          sentinel = s;
          // iOS releases the lock when the page hides — clear our handle so the
          // visibility listener re-acquires on return.
          s.addEventListener("release", () => {
            sentinel = null;
          });
        })
        .catch(() => {
          /* denied / not visible — fine, best-effort */
        });
    };

    acquire();
    const onVis = () => {
      if (document.visibilityState === "visible") acquire();
    };
    document.addEventListener("visibilitychange", onVis);

    return () => {
      cancelled = true;
      document.removeEventListener("visibilitychange", onVis);
      void sentinel?.release().catch(() => {});
      sentinel = null;
    };
  }, [active]);
}
