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
// foreground/visibility signal AND on `online`, and on a self-rearming
// timer. The timer is not redundant with foreground/online: the exact
// scenario in #484 is a tab that is NEVER backgrounded while offline and
// connectivity returns with no `online` event either (observed to not fire
// on every path in Capacitor's WebView) — only time passing.
//
// #484 F6: the timer is neither flat nor unconditional. A pass while
// `navigator.onLine` is false is skipped outright — there is no point
// opening IndexedDB and firing a doomed request every interval — and each
// pass that recovers NOTHING backs the next wait off (capped), so a queue
// stuck behind an outage or a genuinely-stuck entry doesn't burn battery and
// network at a flat cadence forever. Any foreground/online signal resets the
// backoff, since it's a concrete reason to believe conditions changed.
//
// DOM/Capacitor access is injected via `DrainScheduleHandles` rather than
// called directly, so the SCHEDULING logic is unit-testable with plain fakes
// (no jsdom) — the same DI shape `recordingQueue.ts` already uses for
// `QueueStorage` and `RecordingDbLoader`. `browserDrainHandles` below is the
// real adapter `App.tsx` runs on, ALSO exported and unit-tested here (#484
// F4) — a fake reimplementing "does visibilitychange work" proves nothing
// about whether the production wiring does the same thing; testing the real
// adapter does. `App.tsx` is reduced to
// `scheduleQueueDrain(runDrain, browserDrainHandles(document, window, app))`.

export interface DrainScheduleHandles {
  /// Register a callback to run on a foreground/visibility signal (a hidden
  /// tab becoming visible, or a backgrounded native app becoming active).
  /// Returns an unsubscribe.
  onForeground(cb: () => void): () => void;
  /// Register a callback for the browser's `online` event — more responsive
  /// than waiting out the backoff once connectivity actually returns.
  /// Returns an unsubscribe.
  onOnline(cb: () => void): () => void;
  /// Whether the network is up right now. `true` on a platform that can't
  /// answer (better to attempt an avoidable request than to wedge a queue
  /// that actually has signal).
  isOnline(): boolean;
  /// Run `cb` ONCE after `delayMs` — a plain `setTimeout`, not a periodic
  /// timer: `scheduleQueueDrain` re-arms it itself so it can change the
  /// delay between runs (the backoff). Returns a canceller.
  schedule(cb: () => void, delayMs: number): () => void;
}

/// Not too aggressive (it's a background retry, not a user action — no need
/// to hammer battery or the network) and not so rare that the #484 scenario
/// (a tab that stays visible and foregrounded the whole time connectivity was
/// down) waits an unreasonable while once signal returns.
export const DEFAULT_DRAIN_INTERVAL_MS = 60_000;

/// #484 F6: the backoff ceiling — a queue that keeps recovering nothing
/// settles here rather than climbing forever, so a foreground/online signal
/// (which resets it) is never more than this far from a fresh attempt even if
/// none ever fires.
export const MAX_DRAIN_INTERVAL_MS = 10 * 60_000;

/// #484 F6: how fast consecutive no-progress passes back off — doubling from
/// `DEFAULT_DRAIN_INTERVAL_MS` reaches `MAX_DRAIN_INTERVAL_MS` in four passes
/// (1/2/4/8 min), not dozens of flat-interval ticks first.
export const DRAIN_BACKOFF_FACTOR = 2;

/// Run `runDrain` now, then again on every foreground/online signal and on a
/// self-rearming timer that backs off after consecutive no-progress passes,
/// until the returned canceller is called. `runDrain` reports whether the
/// pass made progress (recovered at least one recording) — that resets the
/// backoff; a pass that recovers nothing extends the next wait, up to
/// `MAX_DRAIN_INTERVAL_MS`. `drainPendingRecordingsQueue` guards its own
/// re-entrancy (a module-level flag), so overlapping triggers from this
/// can't double-insert; this module additionally never lets more than one
/// timer be outstanding at once (`arm()` always cancels before re-scheduling),
/// so overlapping signals can't leak timers either.
export function scheduleQueueDrain(
  runDrain: () => Promise<boolean> | boolean,
  handles: DrainScheduleHandles,
  baseIntervalMs: number = DEFAULT_DRAIN_INTERVAL_MS,
): () => void {
  let cancelled = false;
  let cancelTimer: (() => void) | null = null;
  let consecutiveNoProgress = 0;

  function nextDelay(): number {
    return Math.min(
      baseIntervalMs * DRAIN_BACKOFF_FACTOR ** consecutiveNoProgress,
      MAX_DRAIN_INTERVAL_MS,
    );
  }

  // Re-arms the recurring timer at the CURRENT backoff delay — always
  // cancelling any timer already outstanding first, so overlapping callers
  // (a signal racing the timer's own re-arm) can never leave two live.
  function arm(): void {
    if (cancelled) return;
    cancelTimer?.();
    cancelTimer = handles.schedule(() => void tick(), nextDelay());
  }

  async function attempt(): Promise<void> {
    // No point opening the store and firing a doomed request — and it isn't
    // "no progress" either, so it must not feed the backoff: the online
    // event (or the next foreground) is what should trigger the real retry.
    if (!handles.isOnline()) return;
    const progressed = await runDrain();
    consecutiveNoProgress = progressed ? 0 : consecutiveNoProgress + 1;
  }

  // The timer's own callback: attempt, THEN re-arm at whatever delay the
  // result just produced — this is what makes the wait grow.
  async function tick(): Promise<void> {
    if (cancelled) return;
    await attempt();
    arm();
  }

  function onSignal(): void {
    // A concrete reason to believe conditions changed: re-arm the timer at
    // the base interval IMMEDIATELY (not waiting for an attempt to resolve —
    // a slow/hung attempt must not leave the timer sitting at whatever the
    // backoff had climbed to), then try. This attempt's own outcome re-arms
    // again once it resolves, same as the timer's own `tick()` — so a
    // no-progress result from THIS attempt still resumes the climb, just
    // from a fresh base rather than continuing where it left off.
    consecutiveNoProgress = 0;
    arm();
    void attempt().then(arm);
  }

  // Both registered synchronously, like the pre-backoff version — a signal
  // or the timer firing is what's async, not the act of subscribing to them.
  // The immediate mount attempt re-arms again once IT resolves too, so the
  // very first backoff step doesn't have to wait for a second trigger.
  arm();
  void attempt().then(arm);
  const cancelForeground = handles.onForeground(onSignal);
  const cancelOnline = handles.onOnline(onSignal);
  return () => {
    cancelled = true;
    cancelForeground();
    cancelOnline();
    cancelTimer?.();
  };
}

/// The subset of `document` `browserDrainHandles` touches.
export interface DocumentLike {
  visibilityState: string;
  addEventListener(type: "visibilitychange", cb: () => void): void;
  removeEventListener(type: "visibilitychange", cb: () => void): void;
}

/// The subset of `window` `browserDrainHandles` touches.
export interface WindowLike {
  setTimeout(cb: () => void, ms: number): number;
  clearTimeout(id: number): void;
  addEventListener(type: "online", cb: () => void): void;
  removeEventListener(type: "online", cb: () => void): void;
  navigator: { onLine: boolean };
}

/// The subset of the Capacitor native bridge `browserDrainHandles` touches —
/// a backgrounded native app becoming active. A web build's bridge has
/// `isNativePlatform()` always `false`, so `addListener` is never called.
export interface NativeAppLike {
  isNativePlatform(): boolean;
  addListener(
    type: "appStateChange",
    cb: (state: { isActive: boolean }) => void,
  ): Promise<{ remove(): void }>;
}

/// #484 F4: the REAL DOM/Capacitor adapter `App.tsx` runs on, extracted out
/// of the component and unit-tested here — the gap the original commit left:
/// its only test exercised a hand-rolled fake `DrainScheduleHandles` the test
/// file itself defined, which proves nothing about whether `App.tsx` wires a
/// `visibilitychange` listener correctly, whether a native `appStateChange`
/// only fires the callback on `isActive`, or whether `navigator.onLine`
/// actually gates a drain. Those are exactly what's tested against this
/// function directly, with fake `DocumentLike`/`WindowLike`/`NativeAppLike`
/// objects instead of jsdom. `App.tsx`'s effect is reduced to
/// `scheduleQueueDrain(runDrain, browserDrainHandles(document, window, app))`
/// — small enough to verify by reading (this repo's WebView-UI testing rung;
/// see CLAUDE.md's iOS/watch testing ladder).
export function browserDrainHandles(
  doc: DocumentLike,
  win: WindowLike,
  native: NativeAppLike,
): DrainScheduleHandles {
  return {
    onForeground(cb) {
      const onVisible = () => {
        if (doc.visibilityState === "visible") cb();
      };
      doc.addEventListener("visibilitychange", onVisible);
      let nativeSub: Promise<{ remove(): void }> | null = null;
      if (native.isNativePlatform()) {
        nativeSub = native.addListener("appStateChange", ({ isActive }) => {
          if (isActive) cb();
        });
      }
      return () => {
        doc.removeEventListener("visibilitychange", onVisible);
        if (nativeSub) void nativeSub.then((h) => h.remove());
      };
    },
    onOnline(cb) {
      win.addEventListener("online", cb);
      return () => win.removeEventListener("online", cb);
    },
    isOnline() {
      return win.navigator.onLine;
    },
    schedule(cb, delayMs) {
      const id = win.setTimeout(cb, delayMs);
      return () => win.clearTimeout(id);
    },
  };
}
