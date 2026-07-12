import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "../lib/supabase";
import { relaySessionToWatch } from "../lib/watchAuthRelay";

export function useAuth() {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setLoading(false);
      relaySessionToWatch(data.session);
    });
    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((_event, s) => {
      setSession(s);
      setLoading(false);
      relaySessionToWatch(s);
    });
    return () => subscription.unsubscribe();
  }, []);

  return {
    session,
    loading,
    signOut: () => supabase.auth.signOut(),
  };
}
