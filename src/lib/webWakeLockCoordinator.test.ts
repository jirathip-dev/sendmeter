import { describe, expect, it, vi } from "vitest";
import { WebWakeLockCoordinator, type WakeLockSentinelLike } from "./webWakeLockCoordinator";

function deferred<T>() {
  let resolve!: (v: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

/// A fake WakeLockSentinel whose `release` event fires only when the test
/// calls `fireRelease()` — lets tests deliver a stale/duplicate event at any
/// point, not just when `release()` is called.
function fakeSentinel(label: string) {
  let listener: (() => void) | null = null;
  const release = vi.fn(async () => {
    listener?.();
  });
  return {
    label,
    release,
    addEventListener: (_type: "release", l: () => void) => {
      listener = l;
    },
    fireRelease: () => listener?.(),
  } satisfies WakeLockSentinelLike & { label: string; fireRelease: () => void };
}

async function flush() {
  await Promise.resolve();
  await Promise.resolve();
}

describe("WebWakeLockCoordinator", () => {
  it("acquires a sentinel and tracks it as held once the request resolves", async () => {
    const a = fakeSentinel("A");
    const d = deferred<typeof a>();
    const request = vi.fn().mockReturnValue(d.promise);
    const coordinator = new WebWakeLockCoordinator(request);

    coordinator.acquire();
    expect(coordinator.isHeld()).toBe(false);
    d.resolve(a);
    await flush();

    expect(coordinator.isHeld()).toBe(true);
  });

  it("a second acquire while the first request is unresolved does not start an untracked second request", async () => {
    const a = fakeSentinel("A");
    const d = deferred<typeof a>();
    const request = vi.fn().mockReturnValue(d.promise);
    const coordinator = new WebWakeLockCoordinator(request);

    coordinator.acquire();
    coordinator.acquire();
    coordinator.acquire();
    expect(request).toHaveBeenCalledTimes(1);

    d.resolve(a);
    await flush();
    expect(coordinator.isHeld()).toBe(true);

    // Already holding a sentinel — still a no-op, not a second request.
    coordinator.acquire();
    expect(request).toHaveBeenCalledTimes(1);
  });

  it("resolution before cleanup: cleanup releases the held sentinel", async () => {
    const a = fakeSentinel("A");
    const d = deferred<typeof a>();
    const request = vi.fn().mockReturnValue(d.promise);
    const coordinator = new WebWakeLockCoordinator(request);

    coordinator.acquire();
    d.resolve(a);
    await flush();
    expect(coordinator.isHeld()).toBe(true);

    coordinator.cleanup();
    expect(coordinator.isHeld()).toBe(false);
    expect(a.release).toHaveBeenCalledTimes(1);
  });

  it("resolution after cleanup: the late sentinel is released immediately and never adopted", async () => {
    const a = fakeSentinel("A");
    const d = deferred<typeof a>();
    const request = vi.fn().mockReturnValue(d.promise);
    const coordinator = new WebWakeLockCoordinator(request);

    coordinator.acquire();
    coordinator.cleanup(); // cleanup fires before the request resolves
    expect(coordinator.isHeld()).toBe(false);

    d.resolve(a);
    await flush();

    expect(coordinator.isHeld()).toBe(false);
    expect(a.release).toHaveBeenCalledTimes(1);

    // Cleanup also blocks any further acquire attempts.
    coordinator.acquire();
    expect(request).toHaveBeenCalledTimes(1);
  });

  it("cleanup with no request ever started is a no-op", () => {
    const request = vi.fn();
    const coordinator = new WebWakeLockCoordinator(request);
    expect(() => coordinator.cleanup()).not.toThrow();
    expect(coordinator.isHeld()).toBe(false);
  });

  it("a stale release event from a superseded sentinel cannot clear the newer active one", async () => {
    const a = fakeSentinel("A");
    const b = fakeSentinel("B");
    const da = deferred<typeof a>();
    const db = deferred<typeof b>();
    const request = vi
      .fn()
      .mockReturnValueOnce(da.promise)
      .mockReturnValueOnce(db.promise);
    const coordinator = new WebWakeLockCoordinator(request);

    coordinator.acquire();
    da.resolve(a);
    await flush();
    expect(coordinator.isHeld()).toBe(true);

    // The browser released A on its own (e.g. the page was hidden); our
    // listener clears the tracked reference, and a visibilitychange-style
    // re-acquire picks up a fresh sentinel B.
    a.fireRelease();
    expect(coordinator.isHeld()).toBe(false);

    coordinator.acquire();
    db.resolve(b);
    await flush();
    expect(coordinator.isHeld()).toBe(true);
    expect(request).toHaveBeenCalledTimes(2);

    // A's release event fires again (a stale/duplicate delivery) — it must
    // not clear B, the currently active sentinel.
    a.fireRelease();
    expect(coordinator.isHeld()).toBe(true);
    expect(b.release).not.toHaveBeenCalled();
  });

  it("a rejected request clears the pending flag so a later acquire can retry", async () => {
    const a = fakeSentinel("A");
    const d1 = deferred<typeof a>();
    const d2 = deferred<typeof a>();
    const request = vi
      .fn()
      .mockReturnValueOnce(d1.promise)
      .mockReturnValueOnce(d2.promise);
    const coordinator = new WebWakeLockCoordinator(request);

    coordinator.acquire();
    d1.reject(new Error("denied"));
    await flush();
    expect(coordinator.isHeld()).toBe(false);

    coordinator.acquire();
    expect(request).toHaveBeenCalledTimes(2);
    d2.resolve(a);
    await flush();
    expect(coordinator.isHeld()).toBe(true);
  });
});
