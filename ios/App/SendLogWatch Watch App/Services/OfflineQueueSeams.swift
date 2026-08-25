import Foundation
import SendLogWatchCore
import Supabase

// MARK: - Issue #475 — injectable seam for OfflineQueue

/// `OfflineQueue` talked straight to `Repo` (static methods) and
/// `FileManager.default` — there was nowhere to inject a fake uploader or a
/// scratch directory, so "a permanent-error item does not block a healthy
/// item" was only checkable by hand, on a real device. This protocol is the
/// production/test seam: `RepoBundleUploader` is the real path,
/// `OfflineQueueTests` (SendLogWatchTests target) supplies a scripted stub.
protocol WorkoutBundleUploading: Sendable {
    func upload(_ bundle: WorkoutSaveBundle) async throws
}

struct RepoBundleUploader: WorkoutBundleUploading {
    func upload(_ bundle: WorkoutSaveBundle) async throws {
        try await Repo.uploadBundle(bundle)
    }
}

/// Quarantine records stamp `quarantinedAt`; tests need a deterministic time
/// instead of the wall clock to assert on it.
protocol QueueClock: Sendable {
    nonisolated func now() -> Date
}

nonisolated struct SystemQueueClock: QueueClock {
    func now() -> Date { Date() }
}

/// Maps whatever `WorkoutBundleUploading.upload` threw into the
/// stage/`UploadFailure` pair `UploadErrorClassifier` (SendLogWatchCore)
/// decides on. Unwraps `StagedUploadError` when present (the real `Repo`
/// path always throws one); a test stub or a genuinely unstaged failure
/// (e.g. a transport error before any stage-specific call) reports `stage:
/// nil` rather than guessing.
///
/// Also computes the one piece of LOCAL evidence the classifier needs
/// (#475 F5) — whether `bundle` itself still carries a non-positive-duration
/// attempt — rather than trusting the server's error message. This is the
/// only place that evidence can be computed: `UploadErrorClassifier` lives
/// in `SendLogWatchCore` and has no reason to know `ClimbAttemptInsert`'s
/// shape, and computing it here keeps the classifier itself Foundation/
/// Supabase-free and testable on Linux.
enum UploadFailureMapping {
    static func classify(_ error: Error, bundle: WorkoutSaveBundle) -> UploadClassification {
        classify(error, hasNonPositiveDurationAttempt: bundle.attempts.contains { $0.durationS <= 0 })
    }

    /// #491: the variant for queue items with no known-permanent rejection
    /// shape (gauge sessions, force recordings). The classifier's
    /// `.quarantine` verdict additionally requires the `.climbAttempts`
    /// stage plus the local zero-duration evidence — neither of which these
    /// uploads can ever present — so items classified through here can only
    /// leave the drain rotation via the bounded `.stuckRetrying` backstop,
    /// never a first-attempt schema quarantine. That is deliberate, not a
    /// gap: quarantining on the FIRST rejection is reserved for the one
    /// failure shape that is positively proven permanent (#475 F12).
    static func classify(_ error: Error) -> UploadClassification {
        classify(error, hasNonPositiveDurationAttempt: false)
    }

    private static func classify(_ error: Error, hasNonPositiveDurationAttempt: Bool) -> UploadClassification {
        let staged = error as? StagedUploadError
        let underlying = staged?.underlying ?? error
        let failure = uploadFailure(from: underlying)
        let outcome = UploadErrorClassifier.classify(
            failure,
            stage: staged?.stage,
            bundleHasNonPositiveDurationAttempt: hasNonPositiveDurationAttempt
        )
        return (staged?.stage, outcome, failure)
    }

    private static func uploadFailure(from error: Error) -> UploadFailure {
        if let postgrestError = error as? PostgrestError {
            return UploadFailure(postgrestCode: postgrestError.code, message: postgrestError.message)
        }
        if let httpError = error as? HTTPError {
            return UploadFailure(httpStatus: httpError.response.statusCode)
        }
        return UploadFailure()
    }
}

// MARK: - Issue #472b — injectable seam for `OfflineQueue`'s auth-relay recovery

/// The seam through which a drain, upon classifying `.needsAuthRelay`, asks
/// the phone for a fresh token. `AuthManager` lives as SwiftUI `@State` on
/// the app root — there is deliberately no `AuthManager.shared` (see its doc
/// comment: identity is owned by the view tree) — so `OfflineQueue`, an
/// actor with no view-tree access, cannot hold a strong reference to it
/// directly. Matches the `uploader`/`clock`/`baseDir` pattern from #475:
/// `AuthManagerRelayRequester` is the production path, `OfflineQueueTests`
/// supplies a recording stub so "a 401 actually asks the phone" is
/// observable rather than inferred from the classifier alone.
protocol SessionRelayRequesting: Sendable {
    func requestSessionRelay() async
}

/// Resolves against `AuthManager.current` (set once, at `init`, by the one
/// instance SwiftUI creates for the app's lifetime). Deliberately does NOT
/// pass `force: true` — `AuthManager.requestSessionFromPhone` already
/// throttles on `SessionRelay.shouldRequestRelay`/`lastRequestAt`, and a
/// second throttle here would only add a place for the two to disagree.
/// `AuthManager.current` being nil (no app instance in this process, e.g. a
/// unit test) makes this a no-op, not a crash.
struct AuthManagerRelayRequester: SessionRelayRequesting {
    func requestSessionRelay() async {
        await AuthManager.current?.requestSessionFromPhone()
    }
}

/// The seam through which `OfflineQueue` schedules a follow-up drain after a
/// pass stalls (#472b) — a bounded backoff so recovery does not depend
/// solely on enqueue/foreground/relay events. `TaskDrainScheduler` is the
/// production path (a real `Task.sleep`); tests inject a scheduler that
/// captures the scheduled action instead of waiting, so "a failed drain
/// retries later with no foreground event" is provable without a test
/// actually sleeping for real minutes.
///
/// A retry callback, wrapped in a concrete `Sendable` type rather than
/// passed as a bare `@Sendable () async -> Void` parameter. This target
/// builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` +
/// `SWIFT_APPROACHABLE_CONCURRENCY = YES`, which bakes an implicit,
/// compiler-internal isolation attribute (`nonisolated(nonsending)`, with no
/// stable source spelling) into a BARE async closure parameter's type here —
/// but `SendLogWatchTests` (a separate target without those defaults) infers
/// no such attribute, so a conformance declared there for a protocol
/// requirement typed with a bare closure parameter fails to match, for a
/// reason that has nothing to do with this seam's actual design. Wrapping
/// the closure inside a nominal type fixes its isolation once, at THIS
/// declaration site, so every conformance — regardless of which target
/// compiles it — refers to the same already-resolved type.
struct RetryAction: Sendable {
    let run: @Sendable () async -> Void
    init(_ run: @escaping @Sendable () async -> Void) { self.run = run }
}

protocol DrainScheduling: Sendable {
    nonisolated func scheduleRetry(after delay: TimeInterval, _ action: RetryAction)
}

struct TaskDrainScheduler: DrainScheduling {
    /// Review F21: an earlier version returned early when the sleep's own
    /// `Task` had been cancelled, without ever running `action`. Nothing
    /// currently cancels this unstructured `Task`, but `OfflineQueue` only
    /// clears its "a retry is armed" flag INSIDE `action` — a dropped action
    /// would disarm the backoff for the rest of the process's lifetime, the
    /// exact indefinite-parking failure this feature exists to prevent. The
    /// action always runs, whether or not the sleep completed early — a
    /// cancelled sleep just means the retry fires sooner, never never.
    nonisolated func scheduleRetry(after delay: TimeInterval, _ action: RetryAction) {
        Task {
            try? await Task.sleep(for: .seconds(delay))
            await action.run()
        }
    }
}
