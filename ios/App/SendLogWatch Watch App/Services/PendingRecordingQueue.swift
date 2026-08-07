import Foundation
import SendLogWatchCore
import Supabase

// MARK: - #486 review F9 — injectable seam for PendingRecordingQueue
//
// `PendingRecordingQueue` originally talked straight to `Repo` (a static
// method) and the real `Documents` directory — there was nowhere to inject a
// scripted uploader or a scratch directory, so every one of its actual
// behaviors (persist → drain → upload → delete, oldest-first ordering, the
// #158 account guard, the `.lost` path) was only checkable by hand on a
// device. Mirrors the `WorkoutBundleUploading`/`baseDir` seam
// `OfflineQueue` gained for the same reason (issue #475): the real path is
// the default, a test supplies a stub.

protocol TindeqRecordingUploading: Sendable {
    func upload(_ row: TindeqRecordingInsert) async throws
}

struct RepoRecordingUploader: TindeqRecordingUploading {
    func upload(_ row: TindeqRecordingInsert) async throws {
        try await Repo.insertTindeqRecording(row)
    }
}

/// The production `EvictionReporting`: an evicted file was a queued, unsynced
/// force recording, so its loss surfaces through the same durable one-shot
/// notice the `.lost` enqueue path uses (#486 re-review R2, CLAUDE.md #264).
struct RecordingLossEvictionReporter: EvictionReporting {
    func recordEviction() { RecordingLossNotice.record() }
}

/// Persist-first queue for individual Tindeq force recordings (#486):
/// `Repo.insertTindeqRecording` used to be a bare `try await …insert(…)`
/// awaited directly by the Stop tap and the disconnect-salvage path — watchOS
/// can suspend the app and freeze that in-flight request at the exact moment
/// a max-effort rep finishes, and unlike a saved workout or gauge session
/// there was no on-disk fallback at all, so the rep was gone outright. Every
/// save is first serialized to Documents/pending-recordings/<uuid>.json, then
/// uploaded and deleted on success. Drained oldest-first on launch /
/// foreground / an accepted auth relay, same triggers as the other two
/// queues.
///
/// Since #491 a thin shell over `UploadQueueEngine`, closing the #486 review
/// F7 gap this issue was filed for: the copy shipped ledger-free ("break on
/// any error", documented at the time as matching the other queues), so one
/// permanently-rejected force recording parked the LARGEST payload of the
/// three queues forever. The engine applies #475's full policy — and its F11
/// exemption: only a failure the server actually evaluated advances the
/// ledger; transport outages and stale tokens park-and-recover instead of
/// quarantining, because a quarantine never heals on its own the way a
/// returning network does.
///
/// This queue is also the one that opts into the engine's
/// evict-oldest-on-refused-write persist path (#486 review F5/R1/R2) — see
/// `UploadQueueEngine.writeWithEviction`.
actor PendingRecordingQueue {
    static let shared = PendingRecordingQueue()

    private let engine: UploadQueueEngine<PendingTindeqRecording>

    init(
        uploader: TindeqRecordingUploading = RepoRecordingUploader(),
        baseDir: URL? = nil,
        clock: QueueClock = SystemQueueClock(),
        sessionRelay: SessionRelayRequesting = AuthManagerRelayRequester(),
        scheduler: DrainScheduling = TaskDrainScheduler(),
        fileIO: QueueFileIO = RealQueueFileIO(),
        evictionReporter: EvictionReporting = RecordingLossEvictionReporter()
    ) {
        engine = UploadQueueEngine(
            slot: .tindeqRecordings,
            directoryName: "pending-recordings",
            lastSyncFileName: "last-successful-sync-recordings.json",
            upload: { try await uploader.upload($0.row) },
            classify: { error, _ in UploadFailureMapping.classify(error) },
            clock: clock,
            baseDir: baseDir ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
            sessionRelay: sessionRelay,
            scheduler: scheduler,
            fileIO: fileIO,
            evictsOldestOnRefusedWrite: true,
            evictionReporter: evictionReporter
        )
    }

    func pendingCount() async -> Int { await engine.pendingCount() }

    @discardableResult
    func quarantinedCount() async -> Int { await engine.quarantinedCount() }

    func enqueue(_ pending: PendingTindeqRecording) async -> QueuePersistOutcome { await engine.enqueue(pending) }

    func drain() async { await engine.drain() }
}

extension PendingRecordingQueue: QueueDepthReporting {
    nonisolated var syncSlot: PendingSyncQueue { .tindeqRecordings }
    func refreshReportedCounts() async { await engine.refreshReportedCounts() }
}

extension PendingTindeqRecording: QueueUploadItem {
    var queueFileId: UUID { row.id }

    /// The sample array IS the recording, so this queue does NOT strip at
    /// quarantine time (see `stripsPayloadOnQuarantine`'s doc) — this hook
    /// only fires as `writeWithEviction`'s disk-full last resort, where the
    /// choice is a 20-times-rejected buffer versus a brand-new rep. The
    /// summary stats (`durationMs`/`peakKg`/`avgKg`/`sampleCount`) survive,
    /// so a later resurrected re-attempt still lands the History row's
    /// headline numbers; `sampleCount` keeps describing what was measured,
    /// while the empty `samples` (plus the record's `payloadDropped`) says
    /// the curve itself was sacrificed.
    func strippedOfHeavyPayload() -> PendingTindeqRecording? {
        guard !row.samples.isEmpty else { return nil }
        var stripped = self
        stripped.row.samples = []
        return stripped
    }
}
