export interface WakeLockSource {
  request: () => Promise<WakeLockSentinel>;
  isVisible: () => boolean;
  onVisibilityChange: (handler: () => void) => () => void;
}

/// Owns the browser Wake Lock promise lifecycle outside React so overlapping
/// requests, late resolutions, and stale release events can be tested
/// directly (mirrors `subscribeToWatchInfo`). `navigator.wakeLock.request()`
/// takes a beat to resolve and the sentinel it returns is the only handle to
/// release later — while it's in flight `sentinel` is still null, so without
/// the `requesting` guard a second visibilitychange/acquire during that
/// window starts an overlapping request. Whichever resolves last silently
/// overwrites the other's reference, leaking the earlier sentinel (never
/// released) and letting a late `release` event from either one clear a
/// reference it may no longer own.
export function subscribeToBrowserWakeLock(source: WakeLockSource): () => void {
  let sentinel: WakeLockSentinel | null = null;
  let requesting = false;
  let cancelled = false;

  const acquire = () => {
    if (sentinel || requesting || cancelled) return;
    requesting = true;
    source
      .request()
      .then((s) => {
        requesting = false;
        if (cancelled) {
          void s.release().catch(() => {});
          return;
        }
        sentinel = s;
        // iOS releases the lock when the page hides — clear our handle so
        // the visibility listener re-acquires on return. Identity-checked so
        // a late release from a since-superseded sentinel can't clear one
        // that has since become current.
        s.addEventListener("release", () => {
          if (sentinel === s) sentinel = null;
        });
      })
      .catch(() => {
        requesting = false;
        /* denied / not visible — fine, best-effort */
      });
  };

  acquire();
  const offVisibility = source.onVisibilityChange(() => {
    if (source.isVisible()) acquire();
  });

  return () => {
    cancelled = true;
    offVisibility();
    void sentinel?.release().catch(() => {});
    sentinel = null;
  };
}
