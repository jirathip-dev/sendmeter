export interface WakeLockSentinelLike {
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
 * in flight or a sentinel is already held, so at most one request is ever
 * outstanding. `cleaned` makes a request that resolves after `cleanup()` get
 * released immediately instead of adopted. The sentinel's own `release`
 * event only clears the tracked reference by identity (`this.sentinel ===
 * s`), so a stale event from a superseded sentinel can't null out a newer
 * one.
 */
export class WebWakeLockCoordinator<S extends WakeLockSentinelLike> {
  private pending = false;
  private sentinel: S | null = null;
  private cleaned = false;

  constructor(private readonly requestSentinel: WakeLockRequester<S>) {}

  /// Idempotent — a no-op while a request is pending, a sentinel is already
  /// held, or cleanup has run.
  acquire(): void {
    if (this.cleaned || this.pending || this.sentinel) return;
    this.pending = true;
    this.requestSentinel()
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
      })
      .catch(() => {
        this.pending = false;
      });
  }

  /// True while a sentinel is currently held.
  isHeld(): boolean {
    return this.sentinel !== null;
  }

  /// Releases the held sentinel (if any) and blocks every later `acquire()`
  /// and any request already in flight from being adopted.
  cleanup(): void {
    this.cleaned = true;
    this.pending = false;
    if (this.sentinel) {
      void this.sentinel.release().catch(() => {});
      this.sentinel = null;
    }
  }
}
