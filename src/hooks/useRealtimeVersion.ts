import { createContext, useContext } from "react";

export const RealtimeVersionContext = createContext(0);

/// Bumps whenever the watch (or another device) writes new session, tindeq,
/// workout, or health data for this user — components fetching that data
/// add this to their effect deps to refetch automatically.
export function useRealtimeVersion(): number {
  return useContext(RealtimeVersionContext);
}
