import { describe, it, expect, vi } from "vitest";
import {
  DEFAULT_DRAIN_INTERVAL_MS,
  DRAIN_BACKOFF_FACTOR,
  MAX_DRAIN_INTERVAL_MS,
  browserDrainHandles,
  scheduleQueueDrain,
  type DrainScheduleHandles,
} from "./drainSchedule";

/// Plain fakes — no jsdom. Captures what was registered so a test can fire it
/// directly, and tracks whether cleanup actually ran. `schedule` is a
/// one-shot primitive (like `setTimeout`) — `scheduleQueueDrain` re-arms it
/// itself, so the fake just remembers the LATEST registration.
function fakeHandles(online = true) {
  let foregroundCb: (() => void) | null = null;
  let onlineCb: (() => void) | null = null;
  let scheduledCb: (() => void) | null = null;
  let scheduledDelayMs: number | null = null;
  let foregroundCancelled = false;
  let onlineCancelled = false;
  let latestTimerCancelled = false;
  let isOnline = online;
  const handles: DrainScheduleHandles = {
    onForeground(cb) {
      foregroundCb = cb;
      return () => {
        foregroundCancelled = true;
      };
    },
    onOnline(cb) {
      onlineCb = cb;
      return () => {
        onlineCancelled = true;
      };
    },
    isOnline: () => isOnline,
    schedule(cb, delayMs) {
      scheduledCb = cb;
      scheduledDelayMs = delayMs;
      latestTimerCancelled = false;
      return () => {
        latestTimerCancelled = true;
      };
    },
  };
  return {
    handles,
    fireForeground: () => foregroundCb?.(),
    fireOnline: () => onlineCb?.(),
    fireScheduled: () => scheduledCb?.(),
    scheduledDelay: () => scheduledDelayMs,
    setOnline: (v: boolean) => {
      isOnline = v;
    },
    foregroundCancelled: () => foregroundCancelled,
    onlineCancelled: () => onlineCancelled,
    latestTimerCancelled: () => latestTimerCancelled,
  };
}

/// Let pending microtasks (the `attempt`/`tick` chain is a couple `await`s
/// deep) resolve before asserting on what they did.
function flush(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

describe("scheduleQueueDrain (#484 F2)", () => {
  it("drains immediately — the pre-existing mount trigger", () => {
    const runDrain = vi.fn(() => true);
    const { handles } = fakeHandles();
    scheduleQueueDrain(runDrain, handles, 60_000);
    expect(runDrain).toHaveBeenCalledTimes(1);
  });

  // PROVED to fail on the old App.tsx: its effect had no foreground/visibility
  // listener at all, so nothing but the initial mount ever called
  // `drainPendingRecordingsQueue`.
  it("drains again on every foreground signal, not just once at schedule time", () => {
    const runDrain = vi.fn(() => true);
    const { handles, fireForeground } = fakeHandles();
    scheduleQueueDrain(runDrain, handles, 60_000);
    fireForeground();
    fireForeground();
    expect(runDrain).toHaveBeenCalledTimes(3); // 1 initial + 2 foreground
  });

  // PROVED to fail on the old App.tsx: it also had no interval/timer at all.
  // This is the scenario named in #484 itself — a tab that goes offline,
  // comes back into signal, and is NEVER backgrounded in between, so no
  // foreground/visibility event fires either.
  it("drains again on the recurring timer even with no foreground signal at all", () => {
    const runDrain = vi.fn(() => true);
    const { handles, fireScheduled } = fakeHandles();
    scheduleQueueDrain(runDrain, handles, 60_000);
    fireScheduled();
    fireScheduled();
    expect(runDrain).toHaveBeenCalledTimes(3); // 1 initial + 2 timer fires
  });

  it("registers the recurring timer at the requested base interval", () => {
    const { handles, scheduledDelay } = fakeHandles();
    scheduleQueueDrain(vi.fn(() => true), handles, 45_000);
    expect(scheduledDelay()).toBe(45_000);
  });

  it("cancels the foreground listener, the online listener, and the timer on cleanup", () => {
    const { handles, foregroundCancelled, onlineCancelled, latestTimerCancelled } =
      fakeHandles();
    const cancel = scheduleQueueDrain(vi.fn(() => true), handles, 60_000);
    expect(foregroundCancelled()).toBe(false);
    expect(onlineCancelled()).toBe(false);
    expect(latestTimerCancelled()).toBe(false);
    cancel();
    expect(foregroundCancelled()).toBe(true);
    expect(onlineCancelled()).toBe(true);
    expect(latestTimerCancelled()).toBe(true);
  });

  // #484 F6 — a flat interval fires a doomed request every tick while
  // offline, on battery, for no possible benefit. There's a better signal
  // for "try again": the `online` event below.
  it("does not call runDrain while offline", () => {
    const runDrain = vi.fn(() => true);
    const { handles, fireScheduled, fireForeground } = fakeHandles(false);
    scheduleQueueDrain(runDrain, handles, 60_000);
    fireScheduled();
    fireForeground();
    expect(runDrain).not.toHaveBeenCalled();
  });

  it("drains on the browser's `online` event — more responsive than waiting out the timer", () => {
    const runDrain = vi.fn(() => true);
    const { handles, fireOnline, setOnline } = fakeHandles(false);
    scheduleQueueDrain(runDrain, handles, 60_000);
    expect(runDrain).not.toHaveBeenCalled(); // offline at mount

    // What the real event means: connectivity actually returned.
    setOnline(true);
    fireOnline();
    expect(runDrain).toHaveBeenCalledTimes(1);
  });

  // #484 F6 — the timer is not flat: a run that recovers nothing backs the
  // NEXT wait off, so a parked queue (the exact scenario a stuck/offline
  // entry creates) doesn't hammer the network at a fixed cadence forever.
  it("backs the timer off after consecutive no-progress runs, capped", async () => {
    const runDrain = vi.fn(() => false); // never makes progress
    const { handles, fireScheduled, scheduledDelay } = fakeHandles();
    scheduleQueueDrain(runDrain, handles, 1000);
    await flush(); // let the initial (mount) attempt settle and re-arm

    expect(scheduledDelay()).toBe(1000 * DRAIN_BACKOFF_FACTOR); // 1 no-progress run so far

    fireScheduled();
    await flush();
    expect(scheduledDelay()).toBe(1000 * DRAIN_BACKOFF_FACTOR ** 2);

    fireScheduled();
    await flush();
    expect(scheduledDelay()).toBe(1000 * DRAIN_BACKOFF_FACTOR ** 3);
  });

  it("never backs off past the cap", async () => {
    const runDrain = vi.fn(() => false);
    const { handles, fireScheduled, scheduledDelay } = fakeHandles();
    scheduleQueueDrain(runDrain, handles, MAX_DRAIN_INTERVAL_MS);
    await flush();
    fireScheduled();
    await flush();
    expect(scheduledDelay()).toBe(MAX_DRAIN_INTERVAL_MS);
  });

  it("resets the backoff once a run makes progress", async () => {
    const runDrain = vi.fn(() => false);
    const { handles, fireScheduled, scheduledDelay } = fakeHandles();
    scheduleQueueDrain(runDrain, handles, 1000);
    await flush();
    fireScheduled();
    await flush();
    expect(scheduledDelay()).toBeGreaterThan(1000); // backed off

    runDrain.mockReturnValue(true); // this run recovers something
    fireScheduled();
    await flush();
    expect(scheduledDelay()).toBe(1000); // back to the base interval
  });

  it("a foreground/online signal resets an already-backed-off timer to the base interval", async () => {
    const runDrain = vi.fn(() => false);
    const { handles, fireScheduled, fireForeground, scheduledDelay } = fakeHandles();
    scheduleQueueDrain(runDrain, handles, 1000);
    await flush();
    fireScheduled();
    await flush();
    expect(scheduledDelay()).toBeGreaterThan(1000); // backed off

    fireForeground();
    expect(scheduledDelay()).toBe(1000); // reset immediately, not after the attempt
  });
});

/// The real DOM/Capacitor adapter (#484 F4) — exercised against fake
/// `document`/`window`/Capacitor objects, not jsdom, matching this repo's
/// jsdom-free `src/lib` convention.
describe("browserDrainHandles (#484 F4 — the real production adapter, not a fake reimplementing it)", () => {
  function fakeDoc(visibilityState: string) {
    const listeners = new Set<() => void>();
    return {
      get visibilityState() {
        return visibilityState;
      },
      set visibilityState(v: string) {
        visibilityState = v;
      },
      addEventListener: (_type: "visibilitychange", cb: () => void) => {
        listeners.add(cb);
      },
      removeEventListener: (_type: "visibilitychange", cb: () => void) => {
        listeners.delete(cb);
      },
      fire: () => {
        for (const cb of listeners) cb();
      },
      listenerCount: () => listeners.size,
    };
  }

  function fakeWin(onLine: boolean) {
    const onlineListeners = new Set<() => void>();
    const timers = new Map<number, () => void>();
    let nextId = 1;
    return {
      navigator: { onLine },
      addEventListener: (_type: "online", cb: () => void) => {
        onlineListeners.add(cb);
      },
      removeEventListener: (_type: "online", cb: () => void) => {
        onlineListeners.delete(cb);
      },
      setTimeout: (cb: () => void) => {
        const id = nextId++;
        timers.set(id, cb);
        return id;
      },
      clearTimeout: (id: number) => {
        timers.delete(id);
      },
      fireOnline: () => {
        for (const cb of onlineListeners) cb();
      },
      onlineListenerCount: () => onlineListeners.size,
      timerCount: () => timers.size,
    };
  }

  function fakeNative(isNative: boolean) {
    const listeners: ((state: { isActive: boolean }) => void)[] = [];
    let removed = 0;
    return {
      isNativePlatform: () => isNative,
      addListener: (
        _type: "appStateChange",
        cb: (state: { isActive: boolean }) => void,
      ) => {
        listeners.push(cb);
        return Promise.resolve({
          remove: () => {
            removed += 1;
          },
        });
      },
      fireActive: (isActive: boolean) => {
        for (const cb of listeners) cb({ isActive });
      },
      removedCount: () => removed,
    };
  }

  it("calls back on visibilitychange to visible, not on hidden", () => {
    const doc = fakeDoc("hidden");
    const cb = vi.fn();
    const handles = browserDrainHandles(doc, fakeWin(true), fakeNative(false));
    handles.onForeground(cb);

    doc.fire();
    expect(cb).not.toHaveBeenCalled();

    doc.visibilityState = "visible";
    doc.fire();
    expect(cb).toHaveBeenCalledTimes(1);
  });

  it("removes the visibilitychange listener on unsubscribe", () => {
    const doc = fakeDoc("visible");
    const handles = browserDrainHandles(doc, fakeWin(true), fakeNative(false));
    const unsub = handles.onForeground(vi.fn());
    expect(doc.listenerCount()).toBe(1);
    unsub();
    expect(doc.listenerCount()).toBe(0);
  });

  it("does not subscribe to appStateChange on a web (non-native) platform", () => {
    const native = fakeNative(false);
    const handles = browserDrainHandles(fakeDoc("visible"), fakeWin(true), native);
    handles.onForeground(vi.fn());
    native.fireActive(true); // no listener registered — must not throw or matter
  });

  it("on native, calls back only when appStateChange reports isActive", () => {
    const native = fakeNative(true);
    const cb = vi.fn();
    const handles = browserDrainHandles(fakeDoc("hidden"), fakeWin(true), native);
    handles.onForeground(cb);

    native.fireActive(false);
    expect(cb).not.toHaveBeenCalled();
    native.fireActive(true);
    expect(cb).toHaveBeenCalledTimes(1);
  });

  it("unsubscribe removes the native listener too", async () => {
    const native = fakeNative(true);
    const handles = browserDrainHandles(fakeDoc("visible"), fakeWin(true), native);
    const unsub = handles.onForeground(vi.fn());
    unsub();
    await Promise.resolve(); // the native unsubscribe resolves via a promise
    expect(native.removedCount()).toBe(1);
  });

  it("isOnline reads navigator.onLine", () => {
    expect(browserDrainHandles(fakeDoc("visible"), fakeWin(true), fakeNative(false)).isOnline()).toBe(
      true,
    );
    expect(
      browserDrainHandles(fakeDoc("visible"), fakeWin(false), fakeNative(false)).isOnline(),
    ).toBe(false);
  });

  it("onOnline subscribes to and unsubscribes from window's online event", () => {
    const win = fakeWin(false);
    const handles = browserDrainHandles(fakeDoc("visible"), win, fakeNative(false));
    const cb = vi.fn();
    const unsub = handles.onOnline(cb);
    expect(win.onlineListenerCount()).toBe(1);
    win.fireOnline();
    expect(cb).toHaveBeenCalledTimes(1);
    unsub();
    expect(win.onlineListenerCount()).toBe(0);
  });

  it("schedule uses window.setTimeout/clearTimeout", () => {
    const win = fakeWin(true);
    const handles = browserDrainHandles(fakeDoc("visible"), win, fakeNative(false));
    const cancel = handles.schedule(vi.fn(), 5000);
    expect(win.timerCount()).toBe(1);
    cancel();
    expect(win.timerCount()).toBe(0);
  });
});

it("DEFAULT_DRAIN_INTERVAL_MS is a sane background-retry cadence", () => {
  expect(DEFAULT_DRAIN_INTERVAL_MS).toBeGreaterThanOrEqual(30_000);
  expect(DEFAULT_DRAIN_INTERVAL_MS).toBeLessThanOrEqual(5 * 60_000);
});
