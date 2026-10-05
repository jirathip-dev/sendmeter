import Foundation

/// The result of a bounded await: the work's own value when it settled inside
/// the deadline, or the fallback with `timedOut == true` when it did not.
public struct AsyncDeadlineOutcome<Value: Sendable>: Sendable {
    public let value: Value
    public let timedOut: Bool

    public init(value: Value, timedOut: Bool) {
        self.value = value
        self.timedOut = timedOut
    }
}

/// #1004: one bounded await, shared by the sign-out drain and the guided
/// launch. Both callers have the same rule: a flag (an upload, a launch) must
/// not be able to outlive the attempt that set it, and the work that is still
/// running must not be cancelled — it simply stops being waited on.
public enum AsyncDeadline {
    /// Resolve to `fallback` if `work` hasn't settled within `timeout`.
    ///
    /// The work is NOT cancelled: there is no way to cancel an in-flight
    /// insert, and no way to cancel the guided launch's resolution — the
    /// caller's own identity guard decides whether a late settlement still
    /// applies (a launch attempt that was superseded settles as `.superseded`,
    /// the same way an insert that lands after the drain deadline removes its
    /// own queue entry).
    public static func race<Value: Sendable>(
        timeout: TimeInterval,
        fallback: Value,
        work: @escaping @Sendable () async -> Value
    ) async -> AsyncDeadlineOutcome<Value> {
        guard timeout > 0 else {
            return AsyncDeadlineOutcome(value: fallback, timedOut: true)
        }
        let box = DeadlineBox(fallback: fallback)
        return await withCheckedContinuation { continuation in
            box.setup(continuation: continuation)
            Task {
                box.finish(DeadlineRaceOutcome(value: await work(), timedOut: false))
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                box.finish(DeadlineRaceOutcome(value: fallback, timedOut: true))
            }
        }
    }

    private struct DeadlineRaceOutcome<Value: Sendable>: Sendable {
        let value: Value
        let timedOut: Bool
    }

    /// The two unstructured tasks above share one resumption point; `finish`
    /// must be called at most once. `@unchecked Sendable` is sound because
    /// every mutation is under the lock.
    private final class DeadlineBox<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private var continuation: CheckedContinuation<AsyncDeadlineOutcome<Value>, Never>?
        private let fallback: Value

        init(fallback: Value) {
            self.fallback = fallback
        }

        func setup(continuation: CheckedContinuation<AsyncDeadlineOutcome<Value>, Never>) {
            lock.lock()
            if let pending = self.continuation {
                // Cannot happen: `setup` runs before either racer exists.
                self.continuation = continuation
                lock.unlock()
                pending.resume(returning: AsyncDeadlineOutcome(value: fallback, timedOut: true))
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func finish(_ outcome: DeadlineRaceOutcome<Value>) {
            lock.lock()
            guard !resumed, let continuation else {
                lock.unlock()
                return
            }
            resumed = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(
                returning: AsyncDeadlineOutcome(value: outcome.value, timedOut: outcome.timedOut)
            )
        }
    }
}
