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
    // Let the request actually get issued before cleanup — this test is
    // about a request already in flight resolving late, distinct from
    // "cleanup landing before the requester is even called" below.
    await Promise.resolve();
    expect(request).toHaveBeenCalledTimes(1);
    coordinator.cleanup(); // cleanup fires before the request resolves
    expect(coordinator.isHeld()).toBe(false);

    d.resolve(a);
    await flush();

    expect(coordinator.isHeld()).toBe(false);
    expect(a.release).toHaveBeenCalledTimes(1);

    // Cleanup also blocks any further acquire attempts — request stays at
    // 1, never retried.
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

  // Round 1, finding 3: a requester that throws synchronously (rather than
  // returning a rejected promise) must not escape acquire() or leave
  // `pending` stuck true forever.
  it("a requester that throws synchronously is caught, clearing pending without wedging a later acquire", async () => {
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

    // A lone acquire() (never swallowed) does not auto-retry — see round 2,
    // finding 1: that's exactly the standing-intent shape that storms.
    expect(request).toHaveBeenCalledTimes(1);
    expect(coordinator.isHeld()).toBe(false);

    // `pending` isn't wedged: a fresh acquire() issues a real second
    // request instead of being silently swallowed.
    coordinator.acquire();
    await flush();
    expect(request).toHaveBeenCalledTimes(2);
    retry.resolve(a);
    await flush();
    expect(coordinator.isHeld()).toBe(true);
  });

  // Round 1, finding 1 (edge-triggered fix, round 2): an acquire() call that
  // lands while a request is already pending is swallowed by the `pending`
  // guard — but the intent it expressed must not be lost outright. The
  // in-flight request's own settlement retries exactly once on its behalf.
  it("an acquire swallowed while a request is pending earns exactly one retry if that request then rejects", async () => {
    const a = fakeSentinel("A");
    const d1 = deferred<typeof a>();
    const d2 = deferred<typeof a>();
    const request = vi
      .fn()
      .mockReturnValueOnce(d1.promise)
      .mockReturnValueOnce(d2.promise);
    const coordinator = new WebWakeLockCoordinator(request);

    coordinator.acquire(); // starts the request, pending
    coordinator.acquire(); // swallowed by the pending guard — earns one retry
    await Promise.resolve();
    expect(request).toHaveBeenCalledTimes(1);

    d1.reject(new Error("NotAllowedError"));
    await flush();

    expect(request).toHaveBeenCalledTimes(2);
    expect(coordinator.isHeld()).toBe(false);

    // No further retries beyond the one earned — draining more turns must
    // not grow the count (round 2, finding 1's storm regression).
    for (let i = 0; i < 50; i++) await Promise.resolve();
    expect(request).toHaveBeenCalledTimes(2);

    d2.resolve(a);
    await flush();
    expect(coordinator.isHeld()).toBe(true);
  });

  it("a rejection after cleanup does not retry — cleanup clears the missed-acquire flag too", async () => {
    const d = deferred<ReturnType<typeof fakeSentinel>>();
    const request = vi.fn().mockReturnValue(d.promise);
    const coordinator = new WebWakeLockCoordinator(request);

    coordinator.acquire();
    coordinator.acquire(); // swallowed — would earn a retry if not for cleanup
    await Promise.resolve(); // let the request actually get issued
    expect(request).toHaveBeenCalledTimes(1);
    coordinator.cleanup();
    d.reject(new Error("denied"));
    await flush();

    expect(request).toHaveBeenCalledTimes(1);
    expect(coordinator.isHeld()).toBe(false);
  });

  // Round 2, finding 2: cleanup() must be able to cancel a request that was
  // only *scheduled* (pending = true synchronously) but not yet actually
  // issued — the requester call itself is one microtask turn away.
  it("cleanup landing before the requester is even called skips issuing the request", async () => {
    const request = vi.fn().mockResolvedValue(fakeSentinel("A"));
    const coordinator = new WebWakeLockCoordinator(request);

    coordinator.acquire();
    coordinator.cleanup(); // lands in the microtask gap before requestSentinel() runs
    await flush();

    expect(request).not.toHaveBeenCalled();
    expect(coordinator.isHeld()).toBe(false);
  });

  // Round 2, finding 1 (the blocker): an always-rejecting requester must
  // never spin. The reviewer measured round 1's standing-intent redrive at
  // 200k requests in 273ms against exactly this shape — unbounded,
  // non-yielding microtask retries with no cap and no task boundary, which
  // starves the macrotask queue (the very visibilitychange that would end
  // it never gets to run).
  it("an always-rejecting requester never spins — at most one retry per swallowed acquire, never a standing loop", async () => {
    const request = vi.fn().mockRejectedValue(new Error("NotAllowedError"));
    const coordinator = new WebWakeLockCoordinator(request);

    coordinator.acquire(); // request 1
    coordinator.acquire(); // swallowed while pending — the one retry it earns
    await flush();

    expect(request).toHaveBeenCalledTimes(2);
    expect(coordinator.isHeld()).toBe(false);

    // The regression this pins: draining many more microtask turns must not
    // grow the count further.
    for (let i = 0; i < 200; i++) await Promise.resolve();
    expect(request).toHaveBeenCalledTimes(2);
  });

  // Round 2, finding 1's "success arm has the same shape": a request that
  // resolves to an already-released sentinel makes hasLiveSentinel() false
  // right after adoption — under a standing-intent redrive that alone would
  // re-trigger a request forever. With no acquire() swallowed during the
  // flight, there is nothing to retry on.
  it("resolving to an already-released sentinel does not retry when no acquire was swallowed", async () => {
    const dead = fakeSentinel("dead");
    dead.markReleasedWithoutEvent();
    const request = vi.fn().mockResolvedValue(dead);
    const coordinator = new WebWakeLockCoordinator(request);

    coordinator.acquire();
    await flush();

    expect(request).toHaveBeenCalledTimes(1);
    expect(coordinator.isHeld()).toBe(false);

    for (let i = 0; i < 200; i++) await Promise.resolve();
    expect(request).toHaveBeenCalledTimes(1);
  });

  it("an acquire swallowed during a request that resolves to an already-released sentinel earns exactly one retry", async () => {
    const dead = fakeSentinel("dead");
    dead.markReleasedWithoutEvent();
    const live = fakeSentinel("live");
    const request = vi.fn().mockResolvedValueOnce(dead).mockResolvedValueOnce(live);
    const coordinator = new WebWakeLockCoordinator(request);

    coordinator.acquire();
    coordinator.acquire(); // swallowed while pending
    await flush();

    expect(request).toHaveBeenCalledTimes(2);
    expect(coordinator.isHeld()).toBe(true);
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

  it("a rejected request clears the pending flag so a later acquire can retry — without a swallowed call, nothing auto-retries", async () => {
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
    // No swallowed acquire happened during the flight, so this does not
    // auto-retry — that would be the standing-intent shape round 2 removed.
    expect(request).toHaveBeenCalledTimes(1);

    // `pending` is cleared, so a fresh acquire() issues a real request.
    coordinator.acquire();
    await flush();
    expect(request).toHaveBeenCalledTimes(2);

    d2.resolve(a);
    await flush();
    expect(coordinator.isHeld()).toBe(true);
  });
});
