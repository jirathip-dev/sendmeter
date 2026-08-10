import { describe, expect, it, vi } from "vitest";
import { subscribeToBrowserWakeLock, type WakeLockSource } from "./browserWakeLock";

function deferred<T>() {
  let resolve!: (v: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

function fakeSentinel() {
  const listeners: Array<() => void> = [];
  return {
    release: vi.fn(async () => {}),
    addEventListener: vi.fn((_type: string, handler: () => void) => {
      listeners.push(handler);
    }),
    // Not part of the real WakeLockSentinel API — a test-only hook to fire
    // the sentinel's own registered release listeners.
    fireRelease: () => listeners.forEach((fn) => fn()),
  } as unknown as WakeLockSentinel & { fireRelease: () => void };
}

function fakeSource(request: WakeLockSource["request"]) {
  let onChange: (() => void) | null = null;
  const source: WakeLockSource = {
    request,
    isVisible: () => true,
    onVisibilityChange: (handler) => {
      onChange = handler;
      return () => {
        onChange = null;
      };
    },
  };
  return { source, fireVisibilityChange: () => onChange?.() };
}

describe("subscribeToBrowserWakeLock", () => {
  it("acquires once on subscribe and releases on cleanup", async () => {
    const sentinel = fakeSentinel();
    const request = vi.fn().mockResolvedValue(sentinel);
    const { source } = fakeSource(request);

    const unsubscribe = subscribeToBrowserWakeLock(source);
    await Promise.resolve();
    await Promise.resolve();
    expect(request).toHaveBeenCalledTimes(1);

    unsubscribe();
    await Promise.resolve();
    expect(sentinel.release).toHaveBeenCalledTimes(1);
  });

  it("a second acquire while the first request is unresolved does not create an untracked sentinel", async () => {
    const first = deferred<WakeLockSentinel>();
    const request = vi.fn().mockReturnValueOnce(first.promise);
    const { source, fireVisibilityChange } = fakeSource(request);

    subscribeToBrowserWakeLock(source);
    // Still pending — a visibility event here must not start a second
    // request while sentinel is still null.
    fireVisibilityChange();
    fireVisibilityChange();
    await Promise.resolve();
    expect(request).toHaveBeenCalledTimes(1);

    const sentinel = fakeSentinel();
    first.resolve(sentinel);
    await Promise.resolve();
    await Promise.resolve();

    // Now that a sentinel is held, further visibility events also must not
    // start a redundant request.
    fireVisibilityChange();
    await Promise.resolve();
    expect(request).toHaveBeenCalledTimes(1);
  });

  it("a request that resolves after unmount/cleanup is immediately released", async () => {
    const first = deferred<WakeLockSentinel>();
    const request = vi.fn().mockReturnValueOnce(first.promise);
    const { source } = fakeSource(request);

    const unsubscribe = subscribeToBrowserWakeLock(source);
    unsubscribe();

    const sentinel = fakeSentinel();
    first.resolve(sentinel);
    await Promise.resolve();
    await Promise.resolve();

    expect(sentinel.release).toHaveBeenCalledTimes(1);
  });

  it("cleanup-before-resolution: cleanup is idempotent and only the late sentinel is released", async () => {
    const first = deferred<WakeLockSentinel>();
    const request = vi.fn().mockReturnValueOnce(first.promise);
    const { source } = fakeSource(request);

    const unsubscribe = subscribeToBrowserWakeLock(source);
    unsubscribe();
    unsubscribe(); // idempotent double-cleanup (React StrictMode-ish)

    const sentinel = fakeSentinel();
    first.resolve(sentinel);
    await Promise.resolve();
    await Promise.resolve();

    expect(sentinel.release).toHaveBeenCalledTimes(1);
  });

  it("an old sentinel's release event cannot clear a newer active sentinel", async () => {
    const first = deferred<WakeLockSentinel>();
    const second = deferred<WakeLockSentinel>();
    let calls = 0;
    const request = vi.fn(() => (calls++ === 0 ? first.promise : second.promise));
    const { source, fireVisibilityChange } = fakeSource(request);

    subscribeToBrowserWakeLock(source);
    const sentinelA = fakeSentinel();
    first.resolve(sentinelA);
    await Promise.resolve();
    await Promise.resolve();

    // iOS releases the lock when the page hides — our own release listener
    // clears the ref, then the page becomes visible again and re-acquires.
    sentinelA.fireRelease();
    fireVisibilityChange();
    await Promise.resolve();

    const sentinelB = fakeSentinel();
    second.resolve(sentinelB);
    await Promise.resolve();
    await Promise.resolve();
    expect(request).toHaveBeenCalledTimes(2);

    // A stray late `release` from the superseded sentinel A must not clear
    // the reference to B — if it did, the next visibility event below would
    // wrongly re-acquire a third time.
    sentinelA.fireRelease();
    fireVisibilityChange();
    await Promise.resolve();
    expect(request).toHaveBeenCalledTimes(2);
  });

  it("cleanup releases every successfully acquired browser sentinel across a reacquire cycle", async () => {
    const first = deferred<WakeLockSentinel>();
    const second = deferred<WakeLockSentinel>();
    let calls = 0;
    const request = vi.fn(() => (calls++ === 0 ? first.promise : second.promise));
    const { source, fireVisibilityChange } = fakeSource(request);

    const unsubscribe = subscribeToBrowserWakeLock(source);
    const sentinelA = fakeSentinel();
    first.resolve(sentinelA);
    await Promise.resolve();
    await Promise.resolve();

    sentinelA.fireRelease();
    fireVisibilityChange();
    await Promise.resolve();

    const sentinelB = fakeSentinel();
    second.resolve(sentinelB);
    await Promise.resolve();
    await Promise.resolve();

    unsubscribe();
    await Promise.resolve();

    expect(sentinelA.release).not.toHaveBeenCalled(); // already released via its own event
    expect(sentinelB.release).toHaveBeenCalledTimes(1);
  });

  it("a denied/rejected request clears the in-flight guard so a later visibility event can retry", async () => {
    const first = deferred<WakeLockSentinel>();
    const sentinel = fakeSentinel();
    let calls = 0;
    const request = vi.fn(() => (calls++ === 0 ? first.promise : Promise.resolve(sentinel)));
    const { source, fireVisibilityChange } = fakeSource(request);

    subscribeToBrowserWakeLock(source);
    first.reject(new Error("denied"));
    await Promise.resolve();
    await Promise.resolve();

    fireVisibilityChange();
    await Promise.resolve();
    await Promise.resolve();

    expect(request).toHaveBeenCalledTimes(2);
  });
});
