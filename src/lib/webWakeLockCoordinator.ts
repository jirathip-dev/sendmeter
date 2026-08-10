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
 * `cleanup()` get released immediately instead of adopted. The sentinel's
 * own `release` event only clears the tracked reference by identity
 * (`this.sentinel === s`), so a stale event from a superseded sentinel can't
 * null out a newer one.
 *
 * `wantsHold` is the standing intent — set by every `acquire()`, cleared
 * only by `cleanup()` — separate from whether a request happens to be
 * outstanding right now. Review round 1 found that without it, an
 * `acquire()` swallowed by the `pending` guard (e.g. a visibilitychange
 * landing mid-request) could vanish for good: if that in-flight request then
 * rejects (`NotAllowedError` is normal when the document was hidden at the
 * moment `request()` actually evaluated visibility), nothing was left to
 * retry, and with no further visibilitychange coming the screen would never
 * re-lock for the rest of the session — a regression against the pre-fix
 * code's simpler always-retry-next-event behavior. `redrive()` re-checks
 * `wantsHold` after every settlement (success *and* failure) and starts a
 * fresh request if the intent is still unmet, so a swallowed acquire keeps
 * its promise instead of being silently dropped.
 */
export class WebWakeLockCoordinator<S extends WakeLockSentinelLike> {
  private pending = false;
  private sentinel: S | null = null;
  private cleaned = false;
  private wantsHold = false;

  constructor(private readonly requestSentinel: WakeLockRequester<S>) {}

  /// Idempotent — a no-op while a request is pending, a live sentinel is
  /// already held, or cleanup has run. Always records the intent to hold,
  /// even when it's a no-op, so a settlement still in flight can re-drive it.
  acquire(): void {
    if (this.cleaned) return;
    this.wantsHold = true;
    if (this.pending || this.hasLiveSentinel()) return;
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
  /// and any request already in flight from being adopted.
  cleanup(): void {
    this.cleaned = true;
    this.wantsHold = false;
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
    // Wrapped in a resolved-promise `.then` so a requester that throws
    // synchronously (rather than returning a rejected promise) still lands
    // in `.catch` below instead of escaping `acquire()` with `pending` stuck
    // true forever.
    Promise.resolve()
      .then(() => this.requestSentinel())
      .then((s) => {
        this.pending = false;
        if (this.cleaned) {
          void s.release().catch(() => {});
          return;
        }
        this.sentinel = s;
        s.addEventListener("release", () => {
          if (this.sentinel === s) this.sentinel = null;
        });
        this.redrive();
      })
      .catch(() => {
        this.pending = false;
        this.redrive();
      });
  }

  /// Starts a fresh request if the standing intent is still unmet — see the
  /// class doc comment for why this can't just be "retry on failure".
  private redrive(): void {
    if (!this.cleaned && this.wantsHold && !this.pending && !this.hasLiveSentinel()) {
      this.startRequest();
    }
  }
}
