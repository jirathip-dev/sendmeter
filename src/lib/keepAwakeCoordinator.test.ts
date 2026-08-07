import { describe, expect, it, vi } from "vitest";
import { KeepAwakeCoordinator } from "./keepAwakeCoordinator";

function deferred() {
  let resolve!: () => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<void>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

describe("KeepAwakeCoordinator", () => {
  it("acquire enables, the last release disables", async () => {
    const calls: boolean[] = [];
    const coordinator = new KeepAwakeCoordinator(async (active) => {
      calls.push(active);
    });

    const release = coordinator.acquire();
    await coordinator.settled();
    expect(calls).toEqual([true]);

    release();
    await coordinator.settled();
    expect(calls).toEqual([true, false]);
  });

  // #493 F-E: the last-write-wins coordinator this replaced would have run
  // allowSleep here — one consumer unmounting released the lock the other
  // still needed. The refcount keeps the screen awake until the LAST holder
  // releases.
  it("one of two holders releasing does not release the other's lock", async () => {
    const calls: boolean[] = [];
    const coordinator = new KeepAwakeCoordinator(async (active) => {
      calls.push(active);
    });

    const releaseA = coordinator.acquire();
    const releaseB = coordinator.acquire();
    await coordinator.settled();
    expect(calls.at(-1)).toBe(true);

    releaseA();
    await coordinator.settled();
    // The wrong value here is a trailing `false`: sleep allowed while B still
    // holds the lock.
    expect(calls).not.toContain(false);

    releaseB();
    await coordinator.settled();
    expect(calls.at(-1)).toBe(false);
  });

  it("a double-fired release is a no-op and cannot steal a later holder's lock", async () => {
    const calls: boolean[] = [];
    const coordinator = new KeepAwakeCoordinator(async (active) => {
      calls.push(active);
    });

    const releaseA = coordinator.acquire();
    releaseA();
    const releaseB = coordinator.acquire();
    await coordinator.settled();
    expect(calls.at(-1)).toBe(true);

    // A releases again (e.g. a React cleanup firing twice). B's hold must
    // survive — a second decrement would drop holds to 0 and allow sleep.
    releaseA();
    await coordinator.settled();
    expect(calls.at(-1)).toBe(true);

    releaseB();
    await coordinator.settled();
    expect(calls.at(-1)).toBe(false);
  });

  it("serializes a rapid acquire/release/acquire burst and ends at the current intent", async () => {
    const first = deferred();
    const calls: boolean[] = [];
    const transition = vi.fn(async (active: boolean) => {
      calls.push(active);
      if (calls.length === 1) await first.promise;
    });
    const coordinator = new KeepAwakeCoordinator(transition);

    const releaseA = coordinator.acquire();
    await Promise.resolve();
    releaseA();
    coordinator.acquire();
    expect(calls).toEqual([true]);

    first.resolve();
    await coordinator.settled();
    // The intermediate release was superseded while the first transition was
    // in flight; the final applied state is the newest intent (held).
    expect(calls.at(-1)).toBe(true);
  });

  it("allows sleep after an in-flight activation finishes on unmount", async () => {
    const first = deferred();
    const calls: boolean[] = [];
    const coordinator = new KeepAwakeCoordinator(async (active) => {
      calls.push(active);
      if (calls.length === 1) await first.promise;
    });

    const release = coordinator.acquire();
    await Promise.resolve();
    release();
    first.resolve();
    await coordinator.settled();

    expect(calls).toEqual([true, false]);
  });

  it("still allows sleep when native activation rejects after taking effect", async () => {
    const first = deferred();
    const calls: boolean[] = [];
    const coordinator = new KeepAwakeCoordinator(async (active) => {
      calls.push(active);
      if (calls.length === 1) await first.promise;
    });

    const release = coordinator.acquire();
    await Promise.resolve();
    release();
    first.reject(new Error("bridge reply lost"));
    await coordinator.settled();

    expect(calls).toEqual([true, false]);
  });

  // #493 review F3: transitions are swallowed-on-failure and never retried,
  // so a failed allowSleep would otherwise leave the idle timer disabled for
  // the rest of the process. reassert() re-applies the CURRENT state — it
  // heals the stuck-awake case without being able to release a live hold.
  it("reassert() retries the idle-timer restore after a swallowed allowSleep failure", async () => {
    const calls: boolean[] = [];
    let failedOnce = false;
    const coordinator = new KeepAwakeCoordinator(async (active) => {
      calls.push(active);
      if (!active && !failedOnce) {
        failedOnce = true;
        throw new Error("bridge hiccup");
      }
    });

    const release = coordinator.acquire();
    await coordinator.settled();
    release();
    await coordinator.settled();
    // The failed allowSleep was swallowed — native idle timer still disabled.
    expect(calls).toEqual([true, false]);

    await coordinator.reassert();
    expect(calls).toEqual([true, false, false]);
  });

  it("reassert() cannot release a hold another consumer still has", async () => {
    const calls: boolean[] = [];
    const coordinator = new KeepAwakeCoordinator(async (active) => {
      calls.push(active);
    });

    coordinator.acquire();
    await coordinator.settled();
    // An unrelated inactive consumer mounting re-asserts while A holds.
    await coordinator.reassert();
    expect(calls).not.toContain(false);
    expect(calls.at(-1)).toBe(true);
  });

  it("continues after a rejected deactivation", async () => {
    const calls: boolean[] = [];
    const coordinator = new KeepAwakeCoordinator(async (active) => {
      calls.push(active);
      if (!active) throw new Error("temporary bridge failure");
    });

    const release = coordinator.acquire();
    await coordinator.settled();
    release();
    await coordinator.settled();
    coordinator.acquire();
    await coordinator.settled();

    expect(calls).toEqual([true, false, true]);
  });
});
