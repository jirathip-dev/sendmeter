export interface WakeLockSentinelLike {
  readonly released: boolean;
  release(): Promise<void>;
  addEventListener(type: "release", listener: () => void): void;
}

export type WakeLockRequester<S extends WakeLockSentinelLike> = () => Promise<S>;

/**
 * Owns the browser Wake Lock promise lifecycle for one consumer (#533). The
 * naive version of this — track only the resolved sentinel — leaves a window
 * while `navigator.wakeLock.request("screen")` is pending where the tracked
 * reference is still `null`, so a second caller (e.g. a visibilitychange
 * firing before the first request resolves) starts an untracked second
 * request. Whichever resolves last wins the reference and the other leaks.
 *
 * `pending` closes that window: `acquire()` is a no-op while a request is
 * in flight or a live sentinel is already held, so at most one request is
 * ever outstanding. `cleaned` makes a request that resolves after
 * `cleanup()` get released immediately instead of adopted — and (review
 * round 2, finding 2) if `cleanup()` lands in the microtask gap before the
 * requester is even called, the request is skipped entirely rather than
 * issued and thrown away. The sentinel's own `release` event only clears the
 * tracked reference by identity (`this.sentinel === s`), so a stale event
 * from a superseded sentinel can't null out a newer one.
 *
 * `missedAcquire` is **edge-triggered**, not standing: it is set only when
 * `acquire()` is swallowed by the pending/live-sentinel guard, and cleared
 * at the top of every `startRequest()`. Review round 1 fixed a real bug
 * (a swallowed acquire's intent could vanish for good if the in-flight
 * request then rejected) with a *standing* "keep wanting a hold until
 * cleanup" flag — but round 2 found that shape is an unbounded, non-yielding
 * microtask retry storm against an always-rejecting requester (measured:
 * 200k requests in 273ms, starving the macrotask queue so the very
 * visibilitychange that would end it never got to run). `missedAcquire`
 * retries **at most once** per swallowed call: `settled()` below only
 * starts a fresh request when `missedAcquire` is still true, and
 * `startRequest()` clears it immediately, so a chain of repeated failures
 * can extend the retry no further than the one swallowed call earned. A
 * consumer that wants more than that relies on the next real
 * `acquire()` (e.g. the next visibilitychange), same as it always has.
 */
export class WebWakeLockCoordinator<S extends WakeLockSentinelLike> {
  private pending = false;
  private sentinel: S | null = null;
  private cleaned = false;
  private missedAcquire = false;

  constructor(private readonly requestSentinel: WakeLockRequester<S>) {}

  /// Idempotent — a no-op while a request is pending, a live sentinel is
  /// already held, or cleanup has run. A swallowed call while pending is
  /// remembered (edge-triggered, see class doc) so that request's own
  /// settlement can retry once on its behalf.
  acquire(): void {
    if (this.cleaned) return;
    if (this.pending || this.hasLiveSentinel()) {
      this.missedAcquire = true;
      return;
    }
    this.startRequest();
  }

  /// True while a live (not yet browser-released) sentinel is held. A
  /// sentinel whose `released` flipped true before its `release` event was
  /// delivered (page freeze / bfcache can queue that event behind a
  /// visibilitychange) must not read as held, or a re-acquire against it
  /// becomes a no-op until the queued event eventually nulls the reference
  /// with nothing left to re-request it.
  isHeld(): boolean {
    return this.hasLiveSentinel();
  }

  /// Releases the held sentinel (if any) and blocks every later `acquire()`
  /// and any request already in flight (issued or merely scheduled) from
  /// being adopted.
  cleanup(): void {
    this.cleaned = true;
    this.missedAcquire = false;
    this.pending = false;
    if (this.sentinel) {
      void this.sentinel.release().catch(() => {});
      this.sentinel = null;
    }
  }

  private hasLiveSentinel(): boolean {
    return this.sentinel !== null && !this.sentinel.released;
  }

  private startRequest(): void {
    this.pending = true;
    this.missedAcquire = false;
    // Wrapped in a resolved-promise `.then` so a requester that throws
    // synchronously (rather than returning a rejected promise) still lands
    // in `.catch` below instead of escaping `acquire()` with `pending` stuck
    // true forever. The `cleaned` re-check here (not just after the request
    // resolves) means a cleanup() landing in this microtask gap skips
    // issuing the request at all, instead of issuing one just to release it.
    Promise.resolve()
      .then(() => (this.cleaned ? null : this.requestSentinel()))
      .then((s) => {
        if (s === null) {
          this.settled();
          return;
        }
        if (this.cleaned) {
          void s.release().catch(() => {});
          this.settled();
          return;
        }
        this.sentinel = s;
        s.addEventListener("release", () => {
          if (this.sentinel === s) this.sentinel = null;
        });
        this.settled();
      })
      .catch(() => {
        this.settled();
      });
  }

  /// Runs after every request settlement (success or failure, including the
  /// cleaned-before-issued case). Retries exactly once if an `acquire()`
  /// was swallowed during this request's flight and the intent is still
  /// unmet — never on a standing basis (see class doc for why that storms).
  private settled(): void {
    this.pending = false;
    if (this.cleaned || !this.missedAcquire || this.hasLiveSentinel()) {
      this.missedAcquire = false;
      return;
    }
    this.startRequest();
  }
}
