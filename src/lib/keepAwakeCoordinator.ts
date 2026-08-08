export type KeepAwakeTransition = (active: boolean) => Promise<void>;

/// Releases one hold taken by `acquire()`. Idempotent — calling it again is a
/// no-op, so a double-firing React cleanup can't release someone else's hold.
export type KeepAwakeRelease = () => void;

/**
 * Refcounts holds on the process-global keep-awake state (#493 F-E: it used
 * to be last-write-wins, safe only while the two `useWakeLock(true)` callers
 * could never co-mount — one consumer unmounting would have released a lock
 * another still needed). The screen stays awake while at least one hold is
 * outstanding; the last release restores the idle timer.
 *
 * Transitions are serialized on a single promise tail. Each state change gets
 * a revision; queued changes that are no longer newest are superseded, while
 * the newest runs after any in-flight transition and reads the hold count at
 * execution time — so the final applied state always reflects the latest
 * intent.
 */
export class KeepAwakeCoordinator {
  private revision = 0;
  private tail = Promise.resolve();
  private holds = 0;

  constructor(private readonly transition: KeepAwakeTransition) {}

  /// Take one hold on the wake lock and schedule the transition. The hold
  /// lasts until the returned release function is called.
  acquire(): KeepAwakeRelease {
    this.holds += 1;
    void this.apply();
    let released = false;
    return () => {
      if (released) return;
      released = true;
      this.holds -= 1;
      void this.apply();
    };
  }

  /// Re-applies the current desired state (#493 review F3). Transitions are
  /// fire-and-forget and a rejected one is swallowed below, so without this
  /// a single failed allowSleep (a bridge hiccup on routine pause) would
  /// leave the idle timer disabled for the rest of the process — the screen
  /// never auto-locks again. Callers re-assert at natural boundaries (an
  /// inactive useWakeLock (re)mount); it applies `holds > 0`, so it can
  /// never release a hold another consumer still has.
  reassert(): Promise<void> {
    return this.apply();
  }

  /// Settles after every transition scheduled so far has run (or been
  /// superseded). Ordering point for tests and callers that must observe the
  /// applied state.
  settled(): Promise<void> {
    return this.tail;
  }

  private apply(): Promise<void> {
    const revision = ++this.revision;
    const work = this.tail.then(async () => {
      // A newer queued change supersedes this one. Its own chained task cannot
      // run until this task resolves, so `settled()` still has a clear
      // ordering point rather than resolving before supersession is known.
      if (revision !== this.revision) return;
      try {
        // Read `holds` here, not at schedule time: only the newest task runs,
        // and the count as-of-now is the only state worth applying.
        await this.transition(this.holds > 0);
      } catch {
        // Keep the chain usable. A later release will still run allowSleep
        // even if an enable rejected after reaching native code.
      }
    });
    this.tail = work;
    return work;
  }
}
