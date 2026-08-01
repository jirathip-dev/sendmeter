import { useEffect } from "react";
import { Capacitor } from "@capacitor/core";
import { KeepAwake } from "@capacitor-community/keep-awake";
import { KeepAwakeCoordinator } from "../lib/keepAwakeCoordinator";

const nativeCoordinator = new KeepAwakeCoordinator((active) =>
  active ? KeepAwake.keepAwake() : KeepAwake.allowSleep(),
);

/// Hold a screen wake lock while `active` — keeps the phone from sleeping
/// mid-recording (users with a short auto-lock kept losing the live gauge).
/// Uses the native Capacitor plugin in the app and the Web Wake Lock API in a
/// browser/PWA. Web locks are re-acquired when the page returns to the
/// foreground because browsers release them whenever the page is hidden.
export function useWakeLock(active: boolean): void {
  useEffect(() => {
    if (!active || Capacitor.isNativePlatform() || typeof navigator === "undefined") return;
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

  useEffect(() => {
    if (!Capacitor.isNativePlatform()) return;
    void nativeCoordinator.setDesired(active);
    return () => {
      // This is process-global native state, so cleanup must explicitly restore
      // the idle timer. The coordinator orders it after any in-flight enable.
      void nativeCoordinator.setDesired(false);
    };
  }, [active]);
}
