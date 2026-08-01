export type KeepAwakeTransition = (active: boolean) => Promise<void>;

/**
 * Serializes process-global keep-awake changes on a single promise tail. Each
 * request gets a revision; queued requests that are no longer current are
 * superseded, while the newest request runs after any in-flight transition so
 * the final applied state always reflects the latest intent.
 */
export class KeepAwakeCoordinator {
  private revision = 0;
  private tail = Promise.resolve();

  constructor(private readonly transition: KeepAwakeTransition) {}

  setDesired(active: boolean): Promise<void> {
    const revision = ++this.revision;
    const work = this.tail.then(async () => {
      // A newer queued intent supersedes this one. Its own chained task cannot
      // run until this task resolves, so the caller's promise still has a clear
      // ordering point rather than resolving before supersession is known.
      if (revision !== this.revision) return;
      try {
        await this.transition(active);
      } catch {
        // Keep the chain usable. A later inactive intent will still run
        // allowSleep even if an enable rejected after reaching native code.
      }
    });
    this.tail = work;
    return work;
  }
}
