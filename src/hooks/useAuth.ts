import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "../lib/supabase";
import { relaySessionToWatch } from "../lib/watchAuthRelay";
import { relayHealthSession, startHealthBackgroundSync } from "../lib/healthSync";

export function useAuth() {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);

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
    } = supabase.auth.onAuthStateChange((_event, s) => {
      setSession(s);
      setLoading(false);
      onSession(s);
    });
    return () => subscription.unsubscribe();
  }, []);

  return {
    session,
    loading,
    signOut: () => supabase.auth.signOut(),
  };
}
