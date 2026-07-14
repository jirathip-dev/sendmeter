import { createContext, useContext } from "react";

export const RealtimeVersionContext = createContext(0);
export const RealtimeBumpContext = createContext<() => void>(() => {});

/// Bumps whenever the watch (or another device) writes new session, tindeq,
/// workout, or health data for this user — components fetching that data
/// add this to their effect deps to refetch automatically.
export function useRealtimeVersion(): number {
  return useContext(RealtimeVersionContext);
}

/// Manually bump the version to force every realtime-keyed card to refetch.
/// Used after local mutations whose realtime echo may not arrive (e.g. the
/// DELETE from "Clear health data & resync" inside the native WebView).
export function useRealtimeBump(): () => void {
  return useContext(RealtimeBumpContext);
}
