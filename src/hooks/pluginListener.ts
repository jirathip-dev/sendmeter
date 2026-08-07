/// Wrap an async Capacitor `addListener(...)` call so the handle it resolves
/// to is removed whenever it arrives — including AFTER the caller has
/// already unsubscribed (a fast unmount, or React StrictMode's
/// mount/unmount/mount in dev).
///
/// #485 F7: `useLiveWorkout`'s and `useLiveForce`'s WatchConnectivity
/// listeners used to store the handle in a `let` variable assigned only
/// inside the `addListener(...).then(...)` callback, and their cleanup read
/// that variable — a decision made from state captured before the
/// resolution it depends on, this repo's named defect class (CLAUDE.md
/// #295/#296). A cleanup that ran BEFORE the promise settled read `null` and
/// removed nothing; the handle that arrived a moment later was never
/// removed, leaking the listener for the rest of the page's life. Keeping
/// the PROMISE itself (not a variable derived from it) and chaining `.then`
/// straight off it — this function, and `useAuth.ts`'s `watchRequest` before
/// it — fires the removal whenever the promise resolves, cleanup-before-
/// resolution or not.
export function subscribePluginListener<H extends { remove: () => Promise<void> }>(
  addListener: () => Promise<H>,
): () => void {
  const listener = addListener();
  return () => {
    void listener.then((handle) => handle.remove());
  };
}
