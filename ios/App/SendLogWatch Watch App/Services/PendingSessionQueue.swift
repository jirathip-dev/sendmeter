import Foundation
import SendLogWatchCore
import Supabase

/// #491: the injectable uploader seam `PendingSessionQueue` never had —
/// before the consolidation it called `Repo.logTindeqSession` directly, so
/// none of its behavior was exercisable off-device. Mirrors
/// `WorkoutBundleUploading`/`TindeqRecordingUploading`.
protocol TindeqSessionUploading: Sendable {
    func upload(_ session: PendingTindeqSession) async throws
}

struct RepoSessionUploader: TindeqSessionUploading {
    func upload(_ session: PendingTindeqSession) async throws {
        try await Repo.logTindeqSession(session)
    }
}

/// Persist-first queue for the end-of-gauge-session insert (issue #144):
/// "Log Session" used to `try? await` the network insert directly at the
/// exact moment the user lowers their wrist — watchOS then suspends the app
/// and freezes the in-flight request, so the session row (carrying the
/// group_id every rep needs) could land minutes to hours later, arriving as
/// a loose-recordings orphan on the phone. Every tap is first serialized to
/// Documents/pending-sessions/<uuid>.json, then uploaded and deleted on
/// success. Drained oldest-first on launch / foreground / an accepted auth
/// relay. Replays are safe because the upload is an idempotent upsert on the
/// client-minted session id (see `Repo.logTindeqSession`).
///
/// Since #491 a thin shell over `UploadQueueEngine`, which also brings this
/// queue the #475 retry ledger + quarantine it never had: before, ANY upload
/// failure broke the whole pass, so one permanently-rejected session parked
/// every session behind it forever.
actor PendingSessionQueue {
    static let shared = PendingSessionQueue()

    private let engine: UploadQueueEngine<PendingTindeqSession>

    init(
        uploader: TindeqSessionUploading = RepoSessionUploader(),
        clock: QueueClock = SystemQueueClock(),
        baseDir: URL? = nil,
        sessionRelay: SessionRelayRequesting = AuthManagerRelayRequester(),
        scheduler: DrainScheduling = TaskDrainScheduler()
    ) {
        engine = UploadQueueEngine(
            slot: .tindeqSessions,
            directoryName: "pending-sessions",
            lastSyncFileName: "last-successful-sync-sessions.json",
            upload: { try await uploader.upload($0) },
            classify: { error, _ in UploadFailureMapping.classify(error) },
            clock: clock,
            baseDir: baseDir ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
            sessionRelay: sessionRelay,
            scheduler: scheduler
        )
    }

    func pendingCount() async -> Int { await engine.pendingCount() }

    @discardableResult
    func quarantinedCount() async -> Int { await engine.quarantinedCount() }

    /// #599: header-only diagnostics for the quarantine surface, oldest first.
    func quarantinedDiagnostics() async -> [QuarantineDiagnosticEntry] { await engine.quarantinedDiagnostics() }

    /// #600: restore retryable quarantined items to the pending queue and
    /// drain them now. Returns how many were restored.
    @discardableResult
    func retryQuarantinedItems() async -> Int { await engine.retryQuarantinedItems() }

    /// #606: this queue's quarantine-exit breadcrumb ring, oldest first.
    func quarantineExitHistory() async -> [QuarantineBreadcrumbEntry] { await engine.quarantineExitHistory() }

    func enqueue(_ session: PendingTindeqSession) async -> QueuePersistOutcome { await engine.enqueue(session) }

    func drain() async { await engine.drain() }
}

extension PendingSessionQueue: QueueDepthReporting {
    nonisolated var syncSlot: PendingSyncQueue { .tindeqSessions }
    func refreshReportedCounts() async { await engine.refreshReportedCounts() }
}

extension PendingTindeqSession: QueueUploadItem {
    var queueFileId: UUID { id }

    /// A pending session is a few hundred bytes of scalars — there is no
    /// separable heavy payload to shed.
    func strippedOfHeavyPayload() -> PendingTindeqSession? { nil }
}
