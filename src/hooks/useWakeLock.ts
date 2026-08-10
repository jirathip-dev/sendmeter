import { useEffect } from "react";
import { Capacitor } from "@capacitor/core";
import { KeepAwake } from "@capacitor-community/keep-awake";
import { KeepAwakeCoordinator } from "../lib/keepAwakeCoordinator";
import { subscribeToBrowserWakeLock } from "../lib/browserWakeLock";

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

    return subscribeToBrowserWakeLock({
      request: () => wl.request("screen"),
      isVisible: () => document.visibilityState === "visible",
      onVisibilityChange: (handler) => {
        document.addEventListener("visibilitychange", handler);
        return () => document.removeEventListener("visibilitychange", handler);
      },
    });
  }, [active]);

  useEffect(() => {
    if (!Capacitor.isNativePlatform()) return;
    if (!active) {
      // Re-assert on every inactive (re)mount (#493 review F3): the
      // coordinator swallows a rejected native transition and never retries,
      // so without this a single failed allowSleep — a bridge hiccup on
      // routine pause — would keep the screen from ever auto-locking again
      // this process. This restores the old setDesired(false)-on-inactive
      // self-healing, refcount-safely: reassert applies the current hold
      // count, so it cannot release a hold another consumer still has.
      void nativeCoordinator.reassert();
      return;
    }
    // This is process-global native state (#493 F-E): each active consumer
    // holds one refcounted acquire, so one unmounting can't release a lock
    // another still needs. The coordinator serializes the underlying native
    // transitions; the last release restores the idle timer.
    return nativeCoordinator.acquire();
  }, [active]);
}
