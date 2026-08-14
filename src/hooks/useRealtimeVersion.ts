import { createContext, useContext } from "react";
import type { RealtimeRecordingRowEvent } from "../lib/realtimeRecordingApply";

export interface RealtimeVersionState {
  version: number;
  /// Latest `tindeq_recordings` postgres_changes events, newest last, bounded
  /// (#613). ForceView applies these directly to its own recordings list so
  /// its own (or any) recording write doesn't need a whole-list refetch; the
  /// generic `version` bump remains the coarse cross-device reconciliation
  /// signal for every other consumer.
  recordingEvents: RealtimeRecordingRowEvent[];
  /// True when events were dropped from the bounded queue (a burst larger than
  /// the cap) — the apply path missed rows, so the ForceView fetch guard must
  /// NOT skip the reconciling refetch for the rest of the session.
  recordingEventsOverflowed: boolean;
}

export const RealtimeVersionContext = createContext<RealtimeVersionState>({
  version: 0,
  recordingEvents: [],
  recordingEventsOverflowed: false,
});
export const RealtimeBumpContext = createContext<() => void>(() => {});

/// Bumps whenever the watch (or another device) writes new session, tindeq,
/// workout, or health data for this user — components fetching that data
/// add this to their effect deps to refetch automatically.
export function useRealtimeVersion(): number {
  return useContext(RealtimeVersionContext).version;
}

/// The bounded queue of recent `tindeq_recordings` realtime events (#613) —
/// the payload-based half of ForceView's recordings reconciliation. See
/// `realtimeRecordingApply.ts` for the pure apply logic.
export function useRealtimeRecordingEvents(): RealtimeRecordingRowEvent[] {
  return useContext(RealtimeVersionContext).recordingEvents;
}

/// Whether the recording-event queue ever overflowed (see
/// `RealtimeVersionState.recordingEventsOverflowed`).
export function useRealtimeRecordingOverflowed(): boolean {
  return useContext(RealtimeVersionContext).recordingEventsOverflowed;
}

/// Manually bump the version to force every realtime-keyed card to refetch.
/// Used after local mutations whose realtime echo may not arrive (e.g. the
/// DELETE from "Clear health data & resync" inside the native WebView).
export function useRealtimeBump(): () => void {
  return useContext(RealtimeBumpContext);
}
