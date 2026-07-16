import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "../lib/supabase";
import { relaySessionToWatch } from "../lib/watchAuthRelay";
import { relayHealthSession, startHealthBackgroundSync } from "../lib/healthSync";

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
      if (s && !healthStarted) {
        healthStarted = true;
        void startHealthBackgroundSync();
      }
    }

    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setLoading(false);
      onSession(data.session);
    });
    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((event, s) => {
      if (event === "PASSWORD_RECOVERY") setRecovery(true);
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
      // would catch it.
      void supabase.auth.getSession().then(({ data }) => {
        setSession(data.session);
        onSession(data.session);
      });
    };
    document.addEventListener("visibilitychange", onVisible);

    // Native deep-link recovery: setSession (from a reset link) fires SIGNED_IN,
    // not PASSWORD_RECOVERY, so deepLinks.ts dispatches this to trigger the
    // set-new-password screen (the web recovery fires PASSWORD_RECOVERY above).
    const onRecovery = () => setRecovery(true);
    window.addEventListener("sendmeter:recovery", onRecovery);

    return () => {
      subscription.unsubscribe();
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("sendmeter:recovery", onRecovery);
    };
  }, []);

  return {
    session,
    loading,
    recovery,
    clearRecovery: () => setRecovery(false),
    signOut: () => supabase.auth.signOut(),
  };
}
