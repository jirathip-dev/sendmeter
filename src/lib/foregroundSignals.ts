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
///   own active transition (backgrounded → active, screen locked → unlocked).
///   WKWebView does not reliably re-fire `visibilitychange` on every resume:
///   a phone that stays nominally foregrounded while locked keeps the
///   document `visible`, so only `appStateChange` marks the actual return.
///
/// Prior to #612 `useAuth` relied on `visibilitychange` alone while every
/// other foreground-sensitive consumer (the queue drain, the pending-uploads
/// counter, the lost-recordings notice) already subscribed to both. The
/// consequence was a stale-bearer-relay window: the watch's token-expiry
/// recovery and the health plugin's sync both wait on the phone re-relaying
/// a current access token when the user foregrounds, and a missed
/// `visibilitychange` delayed that until the auth-js auto-refresh tick fired
/// (~30s) or missed it entirely for a clamped WebView.
///
/// Deliberately a plain function over injected handles (same DI shape as
/// `browserDrainHandles`) so the wiring is unit-testable without a native
/// shell. `subscribe` returns an unsubscribe; the native `addListener` handle
/// is removed even when it resolves AFTER unsubscribe (the #485 F7 shape — a
/// cleanup that read a not-yet-assigned variable would have removed nothing),
/// and a rejected registration is swallowed, not surfaced as an unhandled
/// rejection.

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
    nativeSub = native.addListener("appStateChange", ({ isActive }) => {
      if (isActive) cb();
    });
  }
  return () => {
    doc.removeEventListener("visibilitychange", onVisible);
    // Chained off the PROMISE, not a variable derived from it: a cleanup
    // that ran before `addListener` resolved still removes the eventual
    // handle, and a rejecting registration must not surface as an unhandled
    // promise rejection (the pre-#485 NIT shape had the same exposure).
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
