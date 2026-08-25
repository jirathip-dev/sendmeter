import Foundation

/// Refcounts holds on the process-wide keep-awake state — the native analog
/// of the web's `KeepAwakeCoordinator` (`src/lib/keepAwakeCoordinator.ts`,
/// #493 F-E: it used to be last-write-wins, safe only while the two
/// `useWakeLock(true)` callers could never co-mount — one consumer unmounting
/// would have released a lock another still needed). The screen stays awake
/// while at least one hold is outstanding; the last release restores the idle
/// timer.
///
/// Transitions are serialized on a single tail with revision supersession:
/// each state change gets a revision, queued changes that are no longer
/// newest are superseded, and the newest reads the hold count at execution
/// time — so the final applied state always reflects the latest intent, and a
/// rejected transition (the `UIApplication` write is best-effort) can never
/// wedge the idle timer, because `reassert()` re-applies `holds > 0` and
/// `holds > 0` is the only state worth applying.
@MainActor
public final class KeepAwakeCoordinator {
    public typealias KeepAwakeRelease = () -> Void

    private var holds = 0
    private var revision = 0
    private var tail: Task<Void, Never>?
    private let transition: (Bool) async -> Void

    public init(transition: @escaping (Bool) async -> Void) {
        self.transition = transition
    }

    /// Take one hold and schedule the transition. The hold lasts until the
    /// returned release function is called.
    public func acquire() -> KeepAwakeRelease {
        holds += 1
        apply()
        var released = false
        return { [weak self] in
            guard let self, !released else { return }
            released = true
            self.holds = max(0, self.holds - 1)
            self.apply()
        }
    }

    /// Re-applies the current desired state — the recovery path for a
    /// rejected transition: without it, one failed enable would leave the
    /// idle timer disabled for the rest of the process. Applies `holds > 0`,
    /// so it can never release a hold another consumer still has.
    public func reassert() async {
        await apply()
    }

    /// Settles after every transition scheduled so far has run (or been
    /// superseded). Ordering point for tests and callers that must observe
    /// the applied state.
    public func settled() async {
        await tail?.value
    }

    public var holdCount: Int { holds }

    @discardableResult
    private func apply() -> Task<Void, Never> {
        let currentRevision = revision + 1
        revision = currentRevision
        // Capture the PREVIOUS tail at schedule time — reading `self.tail` at
        // run time would await the task we're about to assign there: itself.
        let previous = tail
        let work = Task { [weak self] in
            if let previous {
                await previous.value
            }
            guard let self else { return }
            // A newer queued change supersedes this one. Its own chained task
            // cannot run until this task resolves, so `settled()` still has a
            // clear ordering point rather than resolving before supersession
            // is known.
            guard currentRevision == self.revision else { return }
            // Read `holds` here, not at schedule time: only the newest task
            // runs, and the count as-of-now is the only state worth applying.
            await self.transition(self.holds > 0)
        }
        tail = work
        return work
    }
}
