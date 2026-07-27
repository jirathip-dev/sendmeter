import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase, SUPABASE_URL } from "../lib/supabase";
import {
  getSessionWithDiagnostics,
  initAuthDiagnostics,
  markUserSignOut,
  recordAuthStateChange,
  recordSessionHeartbeat,
} from "../lib/authDiagnostics";
import { flushAuthEvents } from "../lib/authEventFlush";
import { upsertAuthEvents } from "../lib/repo";
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

export function useAuth() {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  // True after the user lands via a password-reset email link — the app then
  // prompts for a new password instead of dropping them into the dashboard.
  const [recovery, setRecovery] = useState(false);

  useEffect(() => {
    // Kick off HealthKit auth + background delivery once, after the first
    // session is known (no-op on web / until a session exists).
    let healthStarted = false;
    function onSession(s: Session | null) {
      relaySessionToWatch(s);
      relayHealthSession(s);
      // #227: the auth uuid is the ONLY identity attached to an error report —
      // same key `auth_events` uses, never the email.
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
        // Ship whatever the ring holds. Fire-and-forget and idempotent —
        // flushAuthEvents never throws and skips the network entirely when
        // nothing changed since the last successful send.
        void flushAuthEvents(s.user.id, { upsert: upsertAuthEvents });
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

    // A null session here (issue #194) is otherwise indistinguishable
    // between "never logged in", a network hiccup, and auth-js having
    // silently cleared a revoked stored session — see authDiagnostics.ts.
    getSessionWithDiagnostics(supabase, SUPABASE_URL).then(({ session }) => {
      setSession(session);
      setLoading(false);
      onSession(session);
    });
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
      setSession(s);
      setLoading(false);
      onSession(s);
    });

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
        setSession(session);
        onSession(session);
        // Pick up anything HealthKit collected while backgrounded (e.g. a
        // wearable sync) right when the user is looking at the readiness
        // card — no-op on web / until a session exists.
        if (session) void syncHealthNow();
      });
    };
    document.addEventListener("visibilitychange", onVisible);

    // The watch, waiting on an expired access token, can ask us to re-relay
    // (native only). getSession() returns a phone-refreshed token — the watch
    // consumes it and signs back in with no manual login and no refresh token.
    //
    // `guaranteed: true` queues it with transferUserInfo as well as setting the
    // application context (#266): answering a pull while our token is still
    // valid re-sends the same session, and an unchanged application context is
    // the leading explanation for the pull path never landing.
    //
    // The handle is kept and detached below. Discarding it (the old behaviour)
    // meant nothing could ever remove the listener.
    const watchRequest = onWatchSessionRequest(() => {
      void supabase.auth.getSession().then(({ data }) => {
        relaySessionToWatch(data.session, { guaranteed: true });
      });
    });

    // Native deep-link recovery: setSession (from a reset link) fires SIGNED_IN,
    // not PASSWORD_RECOVERY, so deepLinks.ts dispatches this to trigger the
    // set-new-password screen (the web recovery fires PASSWORD_RECOVERY above).
    const onRecovery = () => setRecovery(true);
    window.addEventListener("sendmeter:recovery", onRecovery);

    return () => {
      subscription.unsubscribe();
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("sendmeter:recovery", onRecovery);
      // addListener is async, so the handle may still be in flight when an
      // effect that mounted and unmounted on the same tick cleans up (React
      // StrictMode in dev does exactly that) — detach whenever it arrives.
      void watchRequest.then((handle) => handle?.remove());
    };
  }, []);

  return {
    session,
    loading,
    recovery,
    clearRecovery: () => setRecovery(false),
    signOut: () => {
      // Tell the diagnostics ring the SIGNED_OUT about to arrive is one the
      // user asked for, so a deliberate logout doesn't read as a revocation.
      markUserSignOut();
      return supabase.auth.signOut();
    },
  };
}
