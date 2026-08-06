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
    func now() -> Date
}

struct SystemQueueClock: QueueClock {
    func now() -> Date { Date() }
}

/// Maps whatever `WorkoutBundleUploading.upload` threw into the
/// stage/`UploadFailure` pair `UploadErrorClassifier` (SendLogWatchCore)
/// decides on. Unwraps `StagedUploadError` when present (the real `Repo`
/// path always throws one); a test stub or a genuinely unstaged failure
/// (e.g. a transport error before any stage-specific call) reports `stage:
/// nil` rather than guessing.
enum UploadFailureMapping {
    static func classify(_ error: Error) -> (stage: UploadStage?, outcome: UploadErrorOutcome, failure: UploadFailure) {
        let staged = error as? StagedUploadError
        let underlying = staged?.underlying ?? error
        let failure = uploadFailure(from: underlying)
        return (staged?.stage, UploadErrorClassifier.classify(failure), failure)
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
