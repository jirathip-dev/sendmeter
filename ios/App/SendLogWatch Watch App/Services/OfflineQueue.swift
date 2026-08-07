import Foundation
import SendLogWatchCore
import Supabase

/// Minimal offline queue for gym basements: every workout save is first
/// serialized to Documents/pending/<uuid>.json, then uploaded and deleted on
/// success. Since #491 this is a thin shell over `UploadQueueEngine` — the
/// three watch queues were line-for-line copies of the same actor, and the
/// retry/quarantine policy (#475) had only ever landed in this one; the
/// engine holds the single shared implementation, this type keeps the name,
/// the singleton, and the seam-shaped init that `OfflineQueueTests` and the
/// app's call sites already use.
///
/// `uploader`/`clock`/`baseDir` are the #475 injectable seam:
/// `OfflineQueue.shared` uses the real Supabase-backed uploader, the wall
/// clock, and the app's real Documents directory; tests construct their own
/// instance with a scripted uploader and a scratch directory so the real
/// `drainPass` control flow — not a reimplementation of it — is what gets
/// exercised.
actor OfflineQueue {
    static let shared = OfflineQueue()

    private let engine: UploadQueueEngine<WorkoutSaveBundle>

    init(
        uploader: WorkoutBundleUploading = RepoBundleUploader(),
        clock: QueueClock = SystemQueueClock(),
        baseDir: URL? = nil,
        sessionRelay: SessionRelayRequesting = AuthManagerRelayRequester(),
        scheduler: DrainScheduling = TaskDrainScheduler()
    ) {
        engine = UploadQueueEngine(
            slot: .workouts,
            directoryName: "pending",
            // The pre-#491 name, so existing installs keep their recorded
            // timestamp (see the engine's `lastSyncFileName` doc).
            lastSyncFileName: "last-successful-sync.json",
            upload: { try await uploader.upload($0) },
            classify: { UploadFailureMapping.classify($0, bundle: $1) },
            clock: clock,
            baseDir: baseDir ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
            sessionRelay: sessionRelay,
            scheduler: scheduler,
            // #481 / #491 review F1: `workout.raw` (the 1Hz debug trace,
            // hundreds of KB with keepRawTrace on) is shed before the
            // potentially-forever quarantine.
            stripsPayloadOnQuarantine: true
        )
    }

    func pendingCount() async -> Int { await engine.pendingCount() }

    @discardableResult
    func quarantinedCount() async -> Int { await engine.quarantinedCount() }

    func enqueue(_ bundle: WorkoutSaveBundle) async -> QueuePersistOutcome { await engine.enqueue(bundle) }

    func drain() async { await engine.drain() }

    func isRetryScheduled() async -> Bool { await engine.isRetryScheduled() }

    func lastSuccessfulSyncAt() async -> Date? { await engine.lastSuccessfulSyncAt() }
}

extension OfflineQueue: QueueDepthReporting {
    nonisolated var syncSlot: PendingSyncQueue { .workouts }
    func refreshReportedCounts() async { await engine.refreshReportedCounts() }
}

extension WorkoutSaveBundle: QueueUploadItem {
    var queueFileId: UUID { workout.id }

    /// The 1Hz raw trace is debug telemetry, not training data — the upload
    /// works with `raw` nil and every user-visible number (attempts, HR,
    /// effort, session row) survives. nil when there is nothing to shed.
    func strippedOfHeavyPayload() -> WorkoutSaveBundle? {
        guard workout.raw != nil else { return nil }
        var stripped = self
        stripped.workout.raw = nil
        return stripped
    }
}
