import { App as CapacitorApp } from "@capacitor/app";
import { Capacitor } from "@capacitor/core";

/// One shared answer to "what counts as the app returning to the
/// foreground", consumed by the recording-queue drain wiring
/// (`browserDrainHandles`, #484) and `useAuth`'s foreground auth re-relay
/// (#612). One implementation is load-bearing: the auth re-relay has to run
/// on the SAME foreground the drain runs on, or a resumed app drains its
/// queue while the watch and health plugin keep a stale access token.
///
/// Two signals, and BOTH are registered on native:
///
/// - `visibilitychange` → `visible` — the browser-tab equivalent, and the
///   WKWebView's own document-visibility change on iOS. This is the only
///   signal the web platform has.
/// - `@capacitor/app`'s `appStateChange` with `isActive` — the native app's
///   own report that it became active, covering both a backgrounded → active
///   resume and the resign-active transitions that never background the app
///   (app-switcher peek, Control Center, a notification banner, a system
///   permission sheet).
///
/// The two arrive on different delivery paths (WebKit's event vs the
/// Capacitor native→JS bridge) and are not guaranteed to fire together, so a
/// relay driven from a single one of them can miss a return the other would
/// have signalled. Subscribing to both is strictly additive — more
/// detections, never fewer — and `useAuth` dedupes the doubled call within
/// one foreground via a bounded time window (`shouldStartForegroundRelay`,
/// see foregroundRelay.ts).
///
/// Deliberately a plain function over injected handles (same DI shape as
/// `browserDrainHandles`) so the wiring is unit-testable without a native
/// shell. `subscribe` returns an unsubscribe; the native `addListener` handle
/// is removed even when it resolves AFTER unsubscribe (the #485 F7 shape — a
/// cleanup that read a not-yet-assigned variable would have removed nothing),
/// and a rejected registration is swallowed AT REGISTRATION, so a missing or
/// failing plugin never surfaces as an unhandled rejection even for a
/// long-lived subscription that is never unsubscribed.

export interface ForegroundSignalsDoc {
  visibilityState: string;
  addEventListener(type: "visibilitychange", cb: () => void): void;
  removeEventListener(type: "visibilitychange", cb: () => void): void;
}

export interface ForegroundSignalsNative {
  isNativePlatform(): boolean;
  addListener(
    type: "appStateChange",
    cb: (state: { isActive: boolean }) => void,
  ): Promise<{ remove(): void }>;
}

export function subscribeForegroundSignals(
  doc: ForegroundSignalsDoc,
  native: ForegroundSignalsNative,
  cb: () => void,
): () => void {
  const onVisible = () => {
    if (doc.visibilityState === "visible") cb();
  };
  doc.addEventListener("visibilitychange", onVisible);
  let nativeSub: Promise<{ remove(): void }> | null = null;
  if (native.isNativePlatform()) {
    const sub = native.addListener("appStateChange", ({ isActive }) => {
      if (isActive) cb();
    });
    // #612 review F4: handle a rejection AT REGISTRATION, not only on
    // teardown. `useAuth` holds this subscription for the whole app lifetime
    // (it is never unsubscribed), so a rejecting registration would otherwise
    // be an unhandled rejection surfaced to monitoring on every launch. The
    // original promise is kept so teardown can still remove the eventual
    // handle.
    void sub.catch(() => {});
    nativeSub = sub;
  }
  return () => {
    doc.removeEventListener("visibilitychange", onVisible);
    // Chained off the PROMISE, not a variable derived from it: a cleanup
    // that ran before `addListener` resolved still removes the eventual
    // handle. (Rejections are already handled at registration; this catch is
    // a defensive backstop for the same promise.)
    if (nativeSub) void nativeSub.then((h) => h.remove()).catch(() => {});
  };
}

/// The real browser/Capacitor wiring `useAuth` subscribes with. No DI at the
/// call site: on web `isNativePlatform()` is false and the native listener
/// is never registered, so a web build pays nothing.
export function browserForegroundSignals(): {
  subscribe(cb: () => void): () => void;
} {
  return {
    subscribe: (cb) =>
      subscribeForegroundSignals(
        document,
        {
          isNativePlatform: () => Capacitor.isNativePlatform(),
          addListener: (type, listener) =>
            CapacitorApp.addListener(type, listener),
        },
        cb,
      ),
  };
}
