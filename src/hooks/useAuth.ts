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
      void supabase.auth.getSession().then(({ data }) => {
        if (data.session) onSession(data.session);
      });
    };
    document.addEventListener("visibilitychange", onVisible);

    return () => {
      subscription.unsubscribe();
      document.removeEventListener("visibilitychange", onVisible);
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
