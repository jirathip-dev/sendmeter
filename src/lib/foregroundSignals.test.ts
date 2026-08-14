import { describe, expect, it, vi } from "vitest";
import { subscribeForegroundSignals } from "./foregroundSignals";

/// #612: the shared foreground-signal primitive (visibilitychange +
/// native appStateChange) is unit-tested with plain fakes — no jsdom, no
/// native shell — the same DI shape `browserDrainHandles` uses in
/// drainSchedule.test.ts. The wiring `useAuth` runs on is this function
/// plus `browserForegroundSignals()`' one-line real adapter; the adapter is
/// verified by reading (it only wires `document` + `@capacitor/app`).

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

type DeferredHandle = { promise: Promise<{ remove(): void }>; resolve: (h: { remove(): void }) => void };

function deferredHandle(): DeferredHandle {
  let resolve!: (h: { remove(): void }) => void;
  const promise = new Promise<{ remove(): void }>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}

function fakeNative(isNative: boolean, pending?: DeferredHandle) {
  const listeners: ((state: { isActive: boolean }) => void)[] = [];
  let removed = 0;
  let rejects = false;
  return {
    isNativePlatform: () => isNative,
    setRejects: () => {
      rejects = true;
    },
    addListener: (
      _type: "appStateChange",
      cb: (state: { isActive: boolean }) => void,
    ) => {
      listeners.push(cb);
      if (rejects) return Promise.reject(new Error("no plugin"));
      if (pending) return pending.promise;
      return Promise.resolve({
        remove: () => {
          removed += 1;
        },
      });
    },
    fireActive: (isActive: boolean) => {
      for (const cb of listeners) cb({ isActive });
    },
    listenerCount: () => listeners.length,
    removedCount: () => removed,
  };
}

describe("subscribeForegroundSignals (#612)", () => {
  it("calls back on visibilitychange to visible, not on hidden (web — no native listener)", () => {
    const doc = fakeDoc("hidden");
    const native = fakeNative(false);
    const cb = vi.fn();
    const unsub = subscribeForegroundSignals(doc, native, cb);

    doc.fire();
    expect(cb).not.toHaveBeenCalled();

    doc.visibilityState = "visible";
    doc.fire();
    expect(cb).toHaveBeenCalledTimes(1);
    expect(native.listenerCount()).toBe(0);

    unsub();
  });

  it("on native registers appStateChange and calls back only when isActive", () => {
    const doc = fakeDoc("visible");
    const native = fakeNative(true);
    const cb = vi.fn();
    const unsub = subscribeForegroundSignals(doc, native, cb);

    native.fireActive(false);
    expect(cb).not.toHaveBeenCalled();
    native.fireActive(true);
    expect(cb).toHaveBeenCalledTimes(1);
    expect(native.listenerCount()).toBe(1);

    unsub();
  });

  it("calls back from BOTH signals on native — visibilitychange and appStateChange both count as foreground", () => {
    const doc = fakeDoc("hidden");
    const native = fakeNative(true);
    const cb = vi.fn();
    const unsub = subscribeForegroundSignals(doc, native, cb);

    doc.visibilityState = "visible";
    doc.fire(); // WKWebView resume path
    native.fireActive(true); // @capacitor/app active path
    expect(cb).toHaveBeenCalledTimes(2);

    unsub();
  });

  it("unsubscribe removes the visibilitychange listener", () => {
    const doc = fakeDoc("visible");
    const unsub = subscribeForegroundSignals(doc, fakeNative(false), vi.fn());
    expect(doc.listenerCount()).toBe(1);
    unsub();
    expect(doc.listenerCount()).toBe(0);
  });

  it("unsubscribe removes the native listener once its handle resolves", async () => {
    const native = fakeNative(true);
    const unsub = subscribeForegroundSignals(fakeDoc("visible"), native, vi.fn());
    unsub();
    await Promise.resolve();
    expect(native.removedCount()).toBe(1);
  });

  it("#485 F7 — removes a native handle that resolves AFTER unsubscribe", async () => {
    const pending = deferredHandle();
    const native = fakeNative(true, pending);
    const unsub = subscribeForegroundSignals(fakeDoc("visible"), native, vi.fn());
    unsub(); // cleanup runs before addListener resolves

    const remove = vi.fn();
    pending.resolve({ remove });
    await Promise.resolve();
    await Promise.resolve();
    expect(remove).toHaveBeenCalledTimes(1);
  });

  /// Node emits `unhandledRejection` only after the microtask queue drains,
  /// at end of tick — asserting after `await Promise.resolve()` would run
  /// before Node could possibly emit, whether or not the rejection was
  /// handled. Awaiting a macrotask makes the assertion meaningful (#612
  /// review F3).
  function flushMacrotask(): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, 0));
  }

  it("swallows a rejected native registration on unsubscribe — no unhandled rejection", async () => {
    const native = fakeNative(true);
    native.setRejects();
    const unsub = subscribeForegroundSignals(fakeDoc("visible"), native, vi.fn());
    const unhandled = vi.fn();
    const onRejection = (e: PromiseRejectionEvent) => unhandled(e.reason);
    process.once("unhandledRejection", onRejection);
    try {
      unsub();
      await flushMacrotask();
      await flushMacrotask();
      expect(unhandled).not.toHaveBeenCalled();
    } finally {
      process.off("unhandledRejection", onRejection);
    }
  });

  it("#612 review F4 — swallows a rejected registration even when NEVER unsubscribed", async () => {
    // useAuth holds this subscription for the whole app lifetime, so the
    // rejection handler must be attached at registration, not only on
    // teardown. Register and never unsubscribe, then give Node a full tick
    // to emit if it is going to.
    const native = fakeNative(true);
    native.setRejects();
    subscribeForegroundSignals(fakeDoc("visible"), native, vi.fn());
    const unhandled = vi.fn();
    const onRejection = (e: PromiseRejectionEvent) => unhandled(e.reason);
    process.once("unhandledRejection", onRejection);
    try {
      await flushMacrotask();
      await flushMacrotask();
      expect(unhandled).not.toHaveBeenCalled();
    } finally {
      process.off("unhandledRejection", onRejection);
    }
  });
});
