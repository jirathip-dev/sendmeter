import { useEffect, useState } from "react";
import type { ReactNode } from "react";
import { supabase } from "../lib/supabase";
import { RealtimeVersionContext } from "../hooks/useRealtimeVersion";

// Every table a watch write can touch. Kept in sync with the
// `alter publication supabase_realtime add table ...` migration.
const WATCHED_TABLES = [
  "sessions",
  "tindeq_recordings",
  "climb_workouts",
  "climb_attempts",
  "health_metrics",
] as const;

/// Subscribes once (at the authed-app root) to postgres_changes for every
/// table the watch writes to, scoped to this user by RLS + the filter.
/// A workout/recording/health row saved from the watch shows up live on the
/// web and iOS app without a manual reload.
export default function RealtimeVersionProvider({
  userId,
  children,
}: {
  userId: string;
  children: ReactNode;
}) {
  const [version, setVersion] = useState(0);

  useEffect(() => {
    const channel = supabase.channel(`user-data-${userId}`);
    for (const table of WATCHED_TABLES) {
      channel.on(
        "postgres_changes",
        { event: "*", schema: "public", table, filter: `user_id=eq.${userId}` },
        () => setVersion((v) => v + 1),
      );
    }
    channel.subscribe();
    return () => {
      void supabase.removeChannel(channel);
    };
  }, [userId]);

  return (
    <RealtimeVersionContext.Provider value={version}>
      {children}
    </RealtimeVersionContext.Provider>
  );
}
