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
/// calls it — lets tests deliver a stale/duplicate/delayed event at any
/// point, not just when `release()` is called. `released` and the event are
/// deliberately separable: `markReleasedWithoutEvent` + `deliverQueuedRelease`
/// model a real browser flipping `released` before dispatching the event (a
/// page-freeze/bfcache ordering — review round 1 finding 2).
function fakeSentinel(label: string) {
  let listener: (() => void) | null = null;
  let releasedFlag = false;
  const release = vi.fn(async () => {
    releasedFlag = true;
    listener?.();
  });
  return {
    label,
    release,
    get released() {
      return releasedFlag;
    },
    addEventListener: (_type: "release", l: () => void) => {
      listener = l;
    },
    /// The browser released this sentinel on its own (page hidden) and
    /// delivered the event immediately — the common case.
    fireRelease: () => {
      releasedFlag = true;
      listener?.();
    },
    markReleasedWithoutEvent: () => {
      releasedFlag = true;
    },
    deliverQueuedRelease: () => listener?.(),
  } satisfies WakeLockSentinelLike & {
    label: string;
    fireRelease: () => void;
    markReleasedWithoutEvent: () => void;
    deliverQueuedRelease: () => void;
  };
}

/// Drains a generous number of microtask turns — the coordinator can chain
/// several `.then`/`.catch` hops per settlement (e.g. an auto-retry from
/// `redrive()` starts a whole new request+promise chain), more than a
/// couple of bare `await Promise.resolve()` reliably drains.
async function flush() {
  for (let i = 0; i < 8; i++) {
    await Promise.resolve();
  }
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
    // requestSentinel() is invoked one microtask turn after acquire() (it's
    // wrapped in a resolved-promise `.then` — see finding 3), so give that
    // turn a chance before checking the call count.
    await Promise.resolve();
    expect(request).toHaveBeenCalledTimes(1);

    d.resolve(a);
    await flush();
    expect(coordinator.isHeld()).toBe(true);

    // Already holding a live sentinel — still a no-op, not a second request.
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

    // Cleanup also blocks any further acquire attempts, including a
    // redrive — request stays at 1, never retried.
    coordinator.acquire();
    await flush();
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

  // Review round 1, finding 2: `released` and the "release" event can arrive
  // out of order — a page freeze / bfcache can queue the event so a
  // visibilitychange (and the re-acquire it drives) runs first.
  it("a sentinel released before its event is delivered is treated as dead, not as a live held lock", async () => {
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

    // The browser flips `released` internally but the event dispatch is
    // queued — `this.sentinel` still points at A.
    a.markReleasedWithoutEvent();

    // A re-acquire (the visibilitychange handler) must see A as dead —
    // not no-op against a reference that looks non-null but isn't live —
    // and start a fresh request.
    coordinator.acquire();
    await Promise.resolve();
    expect(request).toHaveBeenCalledTimes(2);
    db.resolve(b);
    await flush();
    expect(coordinator.isHeld()).toBe(true);

    // A's queued release event finally arrives — must not clear B.
    a.deliverQueuedRelease();
    expect(coordinator.isHeld()).toBe(true);
    expect(b.release).not.toHaveBeenCalled();
  });

  // Review round 1, finding 3: a requester that throws synchronously (rather
  // than returning a rejected promise) must not escape acquire() or leave
  // `pending` stuck true forever.
  it("a requester that throws synchronously is caught, and the standing intent still self-heals", async () => {
    const a = fakeSentinel("A");
    const retry = deferred<typeof a>();
    const request = vi
      .fn()
      .mockImplementationOnce(() => {
        throw new Error("synchronous boom");
      })
      .mockReturnValueOnce(retry.promise);
    const coordinator = new WebWakeLockCoordinator(request);

    expect(() => coordinator.acquire()).not.toThrow();
    await flush();

    // Not wedged: the synchronous throw was caught, `pending` cleared, and
    // the still-unmet intent drove a retry on its own.
    expect(request).toHaveBeenCalledTimes(2);
    retry.resolve(a);
    await flush();
    expect(coordinator.isHeld()).toBe(true);
  });

  // Review round 1, finding 1: an acquire() call that lands while a request
  // is already pending is swallowed by the `pending` guard — but the intent
  // it expressed must not be lost. Without a redrive, a subsequent rejection
  // (NotAllowedError is normal when the document was hidden at the moment
  // `request()` actually evaluated visibility) would leave nothing held and
  // no further visibilitychange coming to retry — the screen would never
  // re-lock for the rest of the session.
  it("an acquire swallowed while a request is pending re-drives itself if that request then rejects", async () => {
    const a = fakeSentinel("A");
    const d1 = deferred<typeof a>();
    const d2 = deferred<typeof a>();
    const request = vi
      .fn()
      .mockReturnValueOnce(d1.promise)
      .mockReturnValueOnce(d2.promise);
    const coordinator = new WebWakeLockCoordinator(request);

    coordinator.acquire(); // starts the request, pending
    coordinator.acquire(); // swallowed by the pending guard
    await Promise.resolve();
    expect(request).toHaveBeenCalledTimes(1);

    d1.reject(new Error("NotAllowedError"));
    await flush();

    expect(request).toHaveBeenCalledTimes(2);
    expect(coordinator.isHeld()).toBe(false);

    d2.resolve(a);
    await flush();
    expect(coordinator.isHeld()).toBe(true);
  });

  it("a rejection after cleanup does not redrive — the standing intent was cleared", async () => {
    const d = deferred<ReturnType<typeof fakeSentinel>>();
    const request = vi.fn().mockReturnValue(d.promise);
    const coordinator = new WebWakeLockCoordinator(request);

    coordinator.acquire();
    coordinator.cleanup();
    d.reject(new Error("denied"));
    await flush();

    expect(request).toHaveBeenCalledTimes(1);
    expect(coordinator.isHeld()).toBe(false);
  });

  // Review round 1, finding 4: cleanup must release exactly the sentinel it
  // currently holds — a predecessor that was already released naturally
  // (its `release` event fired, clearing the reference by identity) was
  // never released *by the coordinator* and must not be released again.
  it("cleanup releases only the currently held sentinel — a naturally-released predecessor is never double-released", async () => {
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

    // The browser released A on its own; the coordinator's own release()
    // is never called for it.
    a.fireRelease();
    expect(a.release).not.toHaveBeenCalled();

    coordinator.acquire();
    db.resolve(b);
    await flush();
    expect(coordinator.isHeld()).toBe(true);

    coordinator.cleanup();
    expect(b.release).toHaveBeenCalledTimes(1);
    expect(a.release).not.toHaveBeenCalled();
  });

  it("a rejected request clears the pending flag so acquire (or a redrive) can retry", async () => {
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
    // The standing intent from the first acquire() already redrove this on
    // its own by the time flush() settles.
    expect(coordinator.isHeld()).toBe(false);
    expect(request).toHaveBeenCalledTimes(2);

    // An explicit acquire() here is redundant (a request is already
    // pending from the redrive) and must stay a no-op, not a third request.
    coordinator.acquire();
    expect(request).toHaveBeenCalledTimes(2);

    d2.resolve(a);
    await flush();
    expect(coordinator.isHeld()).toBe(true);
  });
});
