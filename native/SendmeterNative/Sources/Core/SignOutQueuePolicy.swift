import Foundation

// #632: the native mirror of the web's sign-out queue semantics — the "#273"
// section of the policy block above `persistRecording` in
// `src/lib/recordingQueue.ts`, carried out by `signOutUser` in
// `src/lib/signOut.ts`. The rules, in order:
//
//   * A USER-INITIATED sign-out DRAINS FIRST, then clears only what actually
//     uploaded. On a normal online sign-out that empties the queue with no
//     prompt and no loss, which is the overwhelmingly common case. The drain
//     has to finish BEFORE `auth.signOut()` — afterwards there is no token and
//     every insert 401s — but it is deadlined (`drainTimeout`), because a
//     dead network must not hang sign-out. A drain that times out is simply
//     "could not upload".
//   * ANY REMAINDER IS THE USER'S CALL, asked once, with the count. Only
//     entries that genuinely cannot upload reach this, so the prompt is rare
//     and always has something to decide. An UNCONDITIONAL confirm was
//     rejected by the web review: it would fire mostly on an empty queue and
//     train the user to dismiss the one that matters.
//   * A FORCED OR REVOKED SIGN-OUT NEVER DISCARDS ANYTHING. This helper is
//     invoked ONLY by the explicit user-initiated path (`AppModel.signOut`);
//     the auth-state `.signedOut` event handler never touches the queue, so a
//     revocation (#265) leaves every unsynced entry exactly where it was.
//   * Nothing here ever CLEARS the queue: clearing is exclusively the
//     account-deletion discard (`DurableQueue.discardAll`, after the server
//     confirms) or an upload's own `remove`. There is no second deletion path.
//
// ACCEPTED RESIDUAL, deliberately (same as the web): a user who signs out with
// entries that cannot upload leaves those entries on the device until the
// same account signs back in and drains them. The queue's `accountUserID`
// scoping is load-bearing here: drain and count are always scoped to the
// signing-out account, and there is no unscoped API to reach another
// account's entries.

/// What the user chose at the sign-out remainder prompt.
public enum SignOutRemainderChoice: Equatable, Sendable {
    /// Proceed with the sign-out; whatever could not upload stays on device
    /// for the same account to drain on its next sign-in (the web's accepted
    /// residual).
    case signOut
    /// Abandon the sign-out entirely; the session stays up and nothing was
    /// touched — the honest answer to "you have N unsynced recordings" is
    /// sometimes "wait, let me find wifi first".
    case cancel
}

/// What the pre-sign-out drain did, so the caller (and a test) can see the
/// "could not upload" answer rather than an error.
public struct SignOutDrainOutcome: Equatable, Sendable {
    /// Recordings that reached the server during the drain.
    public let uploaded: Int
    /// Still queued after the drain — what the remainder prompt is about.
    public let remaining: Int
    /// Whether the drain hit its deadline instead of finishing. Not an error:
    /// the drain keeps running in the background and a late success removes
    /// its own entry.
    public let timedOut: Bool

    public init(uploaded: Int, remaining: Int, timedOut: Bool) {
        self.uploaded = uploaded
        self.remaining = remaining
        self.timedOut = timedOut
    }
}

public enum SignOutQueuePolicy {
    /// Mirror of the web's `DRAIN_TIMEOUT_MS` (src/lib/signOut.ts): how long
    /// the pre-sign-out drain gets. It must complete before `auth.signOut()`
    /// (afterwards there is no token), so a hung request would otherwise hang
    /// sign-out — an action the user must always be able to complete.
    /// Generous enough that a working-but-slow connection finishes a handful
    /// of inserts, short enough to stay a pause rather than a hang.
    public static let drainTimeout: TimeInterval = 8

    /// The decision helper for a user-initiated sign-out, mirroring the web's
    /// `signOutUser` ordering (#273):
    ///
    ///   1. drain while the token is still alive — bounded by `timeout`; a
    ///      timed-out drain is "could not upload", not an error, and the work
    ///      is deliberately NOT cancelled (an insert that lands after the
    ///      deadline removes its own entry from the queue).
    ///   2. count what remains, scoped to `userId`.
    ///   3. if anything remains, ask ONCE with the count.
    ///   4. `cancel` abandons the sign-out: returns `(outcome: nil, ...)` and
    ///      `signOut` is never called. Otherwise `signOut` runs and the
    ///      outcome is returned; a thrown `signOut` error rides back in
    ///      `signOutError` so the caller can surface it.
    ///
    /// Never clears the queue. Callable only from the user-initiated path.
    public static func drainBeforeSignOut(
        userId: UUID,
        drain: @escaping (UUID) async -> Int,
        countRemaining: @escaping (UUID) async -> Int,
        askAboutRemainder: @escaping (Int) async -> SignOutRemainderChoice,
        signOut: @escaping () async throws -> Void,
        timeout: TimeInterval = drainTimeout
    ) async -> (outcome: SignOutDrainOutcome?, signOutError: Error?) {
        let (uploaded, timedOut) = await withDeadline(timeout: timeout, fallback: 0) {
            await drain(userId)
        }
        let remaining = await countRemaining(userId)
        if remaining > 0 {
            if await askAboutRemainder(remaining) == .cancel {
                return (nil, nil)
            }
        }
        do {
            try await signOut()
            return (SignOutDrainOutcome(uploaded: uploaded, remaining: remaining, timedOut: timedOut), nil)
        } catch {
            return (SignOutDrainOutcome(uploaded: uploaded, remaining: remaining, timedOut: timedOut), error)
        }
    }

    private enum DeadlineRace<T: Sendable>: Sendable {
        case finished(T)
        case timedOut
    }

    /// Resolve to `fallback` if `work` hasn't settled within `timeout`. The
    /// work is NOT cancelled — there is no way to cancel an in-flight insert —
    /// it just stops being waited on (the web's `withDeadline` is the same
    /// decision, for the same reason: an insert that lands after the deadline
    /// removes its own entry, and one that lands after `signOut()` fails and
    /// leaves the entry exactly where it was). Exactly-once resumption is
    /// guarded by the lock; the loser of the race becomes a no-op.
    private static func withDeadline<T: Sendable>(
        timeout: TimeInterval,
        fallback: T,
        work: @escaping @Sendable () async -> T
    ) async -> (value: T, timedOut: Bool) {
        guard timeout > 0 else { return (fallback, true) }
        let box = DeadlineBox(fallback: fallback)
        return await withCheckedContinuation { continuation in
            box.setup(continuation: continuation)
            Task {
                box.finish(.finished(await work()))
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                box.finish(.timedOut)
            }
        }
    }

    /// The two unstructured tasks above share one resumption point; `finish`
    /// must be called at most once. `@unchecked Sendable` is sound because
    /// every mutation is under the lock.
    private final class DeadlineBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private var continuation: CheckedContinuation<(value: T, timedOut: Bool), Never>?
        private let fallback: T

        init(fallback: T) {
            self.fallback = fallback
        }

        func setup(continuation: CheckedContinuation<(value: T, timedOut: Bool), Never>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func finish(_ race: DeadlineRace<T>) {
            lock.lock()
            guard !resumed, let continuation else {
                lock.unlock()
                return
            }
            resumed = true
            self.continuation = nil
            lock.unlock()
            switch race {
            case let .finished(value):
                continuation.resume(returning: (value, false))
            case .timedOut:
                continuation.resume(returning: (fallback, true))
            }
        }
    }
}
