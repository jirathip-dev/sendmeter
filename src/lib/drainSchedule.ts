// #484 F2: WHEN the recording queue gets a chance to drain.
//
// `drainPendingRecordingsQueue` (recordingQueue.ts) is the DRAIN ITSELF —
// this module is only about what calls it and when. Before this existed,
// AuthedApp's effect called it exactly once, on mount, with deps
// `[userId, toast]` where `toast` is `useCallback`-stable — so a freshly
// authed tab that later went offline and came back into signal had a queue
// that would never move again, while three UI strings (ForceView's "will
// sync automatically" toasts, this queue's own doc comments) told the user
// otherwise. The watch has a foreground trigger, an inbound-relay trigger, a
// post-enqueue trigger and a scheduled backoff; the web had none of them.
//
// `scheduleQueueDrain` is the pure scheduling logic — runs `runDrain`
// immediately (the pre-existing mount trigger), again on every
// foreground/visibility signal, AND on a plain interval. The interval is not
// redundant with foreground: the exact scenario in #484 is a tab that is
// NEVER backgrounded while offline and connectivity returns — no
// visibilitychange or appStateChange event fires for that, only time passing.
//
// DOM/Capacitor access is injected via `DrainScheduleHandles` rather than
// called directly, so this is unit-testable with plain fakes (no jsdom) —
// the same DI shape `recordingQueue.ts` already uses for `QueueStorage` and
// `RecordingDbLoader`. The caller (`App.tsx`) supplies the real
// `document`/`window`/Capacitor wiring; that glue is intentionally thin so
// the logic worth getting wrong — "does a signal actually cause a drain,
// and does cleanup actually stop it" — lives here where it's tested.

export interface DrainScheduleHandles {
  /// Register a callback to run on a foreground/visibility signal (a hidden
  /// tab becoming visible, or a backgrounded native app becoming active).
  /// Returns an unsubscribe.
  onForeground(cb: () => void): () => void;
  /// Schedule `cb` to run every `intervalMs`. Returns a canceller.
  setInterval(cb: () => void, intervalMs: number): () => void;
}

/// Not too aggressive (it's a background retry, not a user action — no need
/// to hammer battery or the network) and not so rare that the #484 scenario
/// (a tab that stays visible and foregrounded the whole time connectivity was
/// down) waits an unreasonable while once signal returns.
export const DEFAULT_DRAIN_INTERVAL_MS = 60_000;

/// Run `runDrain` now, then again on every foreground signal and on a plain
/// interval, until the returned canceller is called. `drainPendingRecordingsQueue`
/// guards its own re-entrancy (a module-level flag), so overlapping triggers
/// from this can't double-insert.
export function scheduleQueueDrain(
  runDrain: () => void,
  handles: DrainScheduleHandles,
  intervalMs: number = DEFAULT_DRAIN_INTERVAL_MS,
): () => void {
  runDrain();
  const cancelForeground = handles.onForeground(runDrain);
  const cancelInterval = handles.setInterval(runDrain, intervalMs);
  return () => {
    cancelForeground();
    cancelInterval();
  };
}
