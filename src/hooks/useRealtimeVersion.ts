import { createContext, useContext } from "react";
import type { RealtimeRecordingRowEvent } from "../lib/realtimeRecordingApply";
import type { RealtimeSessionRowEvent } from "../lib/sessionRealtimeApply";

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
  /// Latest `sessions` postgres_changes events, newest last, bounded (#615).
  /// useTrainingData applies these directly to the training state so a
  /// completed workout's server row reconciles its pending placeholder
  /// without waiting on the coarse refetch; the `version` bump remains for
  /// UPDATE/DELETE events and as the overflow safety net.
  sessionEvents: RealtimeSessionRowEvent[];
  /// True when session events were dropped from the bounded queue — the
  /// apply path missed rows, so the refetch must not be skipped.
  sessionEventsOverflowed: boolean;
}

export const RealtimeVersionContext = createContext<RealtimeVersionState>({
  version: 0,
  recordingEvents: [],
  recordingEventsOverflowed: false,
  sessionEvents: [],
  sessionEventsOverflowed: false,
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

/// The bounded queue of recent `sessions` realtime events (#615) — the
/// payload-based half of pending-workout reconciliation. See
/// `sessionRealtimeApply.ts` for the pure apply logic.
export function useRealtimeSessionEvents(): RealtimeSessionRowEvent[] {
  return useContext(RealtimeVersionContext).sessionEvents;
}

/// Whether the session-event queue ever overflowed (see
/// `RealtimeVersionState.sessionEventsOverflowed`).
export function useRealtimeSessionOverflowed(): boolean {
  return useContext(RealtimeVersionContext).sessionEventsOverflowed;
}

/// Manually bump the version to force every realtime-keyed card to refetch.
/// Used after local mutations whose realtime echo may not arrive (e.g. the
/// DELETE from "Clear health data & resync" inside the native WebView).
export function useRealtimeBump(): () => void {
  return useContext(RealtimeBumpContext);
}
