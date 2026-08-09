import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase, SUPABASE_URL } from "../lib/supabase";
import {
  getSessionWithDiagnostics,
  initAuthDiagnostics,
  recordAuthStateChange,
  recordSessionHeartbeat,
} from "../lib/authDiagnostics";
import { signOutUser, type SignOutOptions } from "../lib/signOut";
import {
  onWatchSessionRequest,
  relaySessionToWatch,
} from "../lib/watchAuthRelay";
import {
  relayHealthSession,
  startHealthBackgroundSync,
  syncHealthNow,
} from "../lib/healthSync";
import { setMonitoringUser } from "../lib/monitoring";

// Keep the local seeded-account implementation out of every production graph.
// Vite folds this compile-time branch before Rollup creates chunks, so the
// dynamic import (and the credentials/warnings it contains) exists only in a
// DEV build. The shared promise also means React StrictMode never starts two
// module loads for one launch.
type DevAuthModule = typeof import("../lib/devAuth");
const devAuthModulePromise: Promise<DevAuthModule | null> = import.meta.env.DEV
  ? import("../lib/devAuth").catch(() => null)
  : Promise.resolve(null);

export function useAuth() {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  // True after the user lands via a password-reset email link — the app then
  // prompts for a new password instead of dropping them into the dashboard.
  const [recovery, setRecovery] = useState(false);

  useEffect(() => {
    const aliveRef = { current: true };
    const appliedSessionRef = {
      current: undefined as Session | null | undefined,
    };
    let authSubscription: { unsubscribe: () => void } | null = null;
    let watchHandle: { remove: () => void } | null = null;
    let removeVisibilityListener: (() => void) | null = null;

    // Kick off HealthKit auth + background delivery once, after the first
    // session is known (no-op on web / until a session exists).
    let healthStarted = false;
    function onSession(s: Session | null) {
      relaySessionToWatch(s);
      relayHealthSession(s);
      // #227: the auth uuid is the ONLY identity attached to an error report —
      // never the email.
      setMonitoringUser(s?.user.id ?? null);
      if (s && !healthStarted) {
        healthStarted = true;
        void startHealthBackgroundSync();
      }
      if (s) {
        // Last-known-good heartbeat (#202): every moment we hold a live
        // session, stamp when we saw it and when it was due to expire. The
        // gap to the next recorded event is what turns a bare cause into
        // "valid at 23:40, gone at 06:50, cause X".
        recordSessionHeartbeat(s);
      }
    }

    // Moves the ring onto Preferences (native) and checks the storage-wipe
    // canary. Must be called SYNCHRONOUSLY, on this tick, before anything
    // below can record: writes are deferred only while an init is in
    // FLIGHT, so a not-yet-started init is indistinguishable from "there
    // will never be one" and writes through to the pre-init store. This
    // used to await the build tag first — a native `App.getInfo()` bridge
    // round-trip — and `getSession()` for a logged-out user (a storage read
    // behind auth-js's lock, no network) wins that race, so the launch-time
    // event recorded with no build and `store: "local-storage"` on native.
    // init resolves the build tag itself now; there is nothing to await here.
    void initAuthDiagnostics();

    function applySession(s: Session | null) {
      if (!aliveRef.current) return;
      appliedSessionRef.current = s;
      setSession(s);
      setLoading(false);
      onSession(s);
    }

    // Native deep-link recovery: setSession (from a reset link) fires SIGNED_IN,
    // not PASSWORD_RECOVERY, so deepLinks.ts dispatches this to trigger the
    // set-new-password screen (the web recovery fires PASSWORD_RECOVERY above).
    const onRecovery = () => setRecovery(true);
    window.addEventListener("sendmeter:recovery", onRecovery);

    // The local auth module is awaited before auth-js listeners are attached.
    // This keeps the INITIAL_SESSION null event behind the DEV-only auto-login
    // decision, preserving the launch splash and the cached-session path while
    // still allowing Rollup to erase the whole implementation in production.
    function startAuth(devAuth: DevAuthModule | null): void {
      if (!aliveRef.current) return;

      const devAutoSignIn = Boolean(
        devAuth?.shouldAutoSignInForLocalDev({
          enabled: import.meta.env.VITE_DEV_AUTO_LOGIN,
          supabaseUrl: SUPABASE_URL,
          pageSearch: window.location.search,
        }),
      );

      // A null session here (issue #194) is otherwise indistinguishable
      // between "never logged in", a network hiccup, and auth-js having
      // silently cleared a revoked stored session — see authDiagnostics.ts.
      void getSessionWithDiagnostics(supabase, SUPABASE_URL).then(
        async ({ session: storedSession }) => {
          if (!aliveRef.current) return;

          if (!storedSession && devAutoSignIn && devAuth) {
            const autoSession = await devAuth.autoSignInForLocalDevOrNull(
              supabase.auth,
            );
            if (!aliveRef.current) return;
            // signInWithPassword normally emits SIGNED_IN before its promise
            // resolves. Only apply the returned session ourselves if that
            // event did not already win the race.
            if (appliedSessionRef.current === undefined) {
              applySession(autoSession);
            }
            return;
          }

          if (appliedSessionRef.current === undefined) applySession(storedSession);
        },
      );
      const {
        data: { subscription },
      } = supabase.auth.onAuthStateChange((event, s) => {
        if (event === "PASSWORD_RECOVERY") setRecovery(true);
        // #202: THE gap the previous instrumentation had. auth-js runs its own
        // refresh loop; when `_callRefreshToken` fails non-retryably on an
        // already-expired access token it calls `_removeSession()` and emits
        // SIGNED_OUT itself (GoTrueClient `_callRefreshToken` → `_removeSession`
        // → `_notifyAllSubscribers('SIGNED_OUT', null)`). That is the overnight
        // logout, and this line used to just `setSession(null)` — no record, no
        // console line, nothing to find the next morning.
        if (!s) recordAuthStateChange(event);
        // Keep the splash visible while the launch path exchanges the seeded
        // local credentials. `?auth` disables this branch for auth UI testing.
        if (event === "INITIAL_SESSION" && !s && devAutoSignIn) return;
        applySession(s);
      });
      authSubscription = subscription;

      // Re-relay the (supabase-js keeps it fresh) session to the watch + health
      // plugin whenever the app returns to the foreground. Those clients don't
      // own the refresh cycle, so this keeps them supplied with a current token
      // right when the user is likely to act (e.g. save a recording on the watch).
      const onVisible = () => {
        if (document.visibilityState !== "visible") return;
        // getSession() auto-refreshes a merely-expired session; a null result
        // means the stored session is gone/revoked (refresh-token rotation can
        // revoke the family across instances). Reflect that so the UI drops to
        // the login screen instead of a zombie authed state — auth-js removes an
        // invalid stored session *without* emitting SIGNED_OUT, so nothing else
        // would catch it. getSessionWithDiagnostics classifies + records *why*
        // (network vs. revoked vs. never stored — issue #194) instead of this
        // staying silent.
        void getSessionWithDiagnostics(supabase, SUPABASE_URL).then(({ session }) => {
          if (!aliveRef.current) return;
          setSession(session);
          onSession(session);
          // Pick up anything HealthKit collected while backgrounded (e.g. a
          // wearable sync) right when the user is looking at the readiness
          // card — no-op on web / until a session exists.
          if (session) void syncHealthNow();
        });
      };
      document.addEventListener("visibilitychange", onVisible);
      removeVisibilityListener = () =>
        document.removeEventListener("visibilitychange", onVisible);

      // The watch, waiting on an expired access token, can ask us to re-relay
      // (native only). getSession() returns a phone-refreshed token — the watch
      // consumes it and signs back in with no manual login and no refresh token.
      //
      // `guaranteed: true` queues it with transferUserInfo as well as setting
      // the application context (#266): answering a pull while our token is still
      // valid re-sends the same session, and an unchanged application context is
      // the leading explanation for the pull path never landing.
      //
      // The resolution continuation owns deferred cleanup: if this effect has
      // already unmounted, it removes the eventual handle itself. Cleanup
      // below only removes a handle that resolved while the effect was alive,
      // so one native listener always has one removal path.
      const watchRequest = onWatchSessionRequest(() => {
        void supabase.auth.getSession().then(({ data }) => {
          // A readiness request may have reached the native phone while the
          // WebView was briefly stale too. Relay the same fresh access token to
          // both native consumers before the health manager retries; neither
          // side ever receives a refresh token.
          relayHealthSession(data.session);
          relaySessionToWatch(data.session, { guaranteed: true });
        });
      });
      void watchRequest.then((handle) => {
        if (!handle) return;
        if (!aliveRef.current) {
          void handle.remove();
          return;
        }
        watchHandle = handle;
      });
    }

    // Production and explicit auth-screen launches retain the original
    // synchronous bootstrap. Only a normal DEV launch waits for the isolated
    // helper so INITIAL_SESSION null can be held behind its decision.
    if (
      import.meta.env.DEV &&
      !new URLSearchParams(window.location.search).has("auth")
    ) {
      void devAuthModulePromise.then(startAuth);
    } else {
      startAuth(null);
    }

    return () => {
      aliveRef.current = false;
      window.removeEventListener("sendmeter:recovery", onRecovery);
      // addListener is async, so the handle may still be in flight when an
      // effect that mounted and unmounted on the same tick cleans up (React
      // StrictMode in dev does exactly that) — detach whenever it arrives.
      authSubscription?.unsubscribe();
      removeVisibilityListener?.();
      if (watchHandle) void watchHandle.remove();
    };
  }, []);

  return {
    session,
    loading,
    recovery,
    clearRecovery: () => setRecovery(false),
    // #273: one implementation, shared with `deleteAccount` — it marks the
    // SIGNED_OUT as user-initiated (so a deliberate logout doesn't read as a
    // revocation), and first drains the offline recording queue while the
    // token is still alive. The caller supplies the prompt for anything that
    // wouldn't upload; see `signOut.ts`.
    signOut: (opts: Omit<SignOutOptions, "userId"> = {}) =>
      signOutUser({ ...opts, userId: session?.user.id ?? null }),
  };
}
