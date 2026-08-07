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

/// Persist-first queue for individual Tindeq force recordings (#486),
/// mirroring `OfflineQueue`/`PendingSessionQueue` exactly: `Repo.insertTindeqRecording`
/// used to be a bare `try await …insert(…)` awaited directly by the Stop tap
/// and the disconnect-salvage path — watchOS can suspend the app and freeze
/// that in-flight request at the exact moment a max-effort rep finishes, and
/// unlike a saved workout or gauge session there was no on-disk fallback at
/// all, so the rep was gone outright. Every save is first serialized to
/// Documents/pending-recordings/<uuid>.json, then uploaded and deleted on
/// success. Drained oldest-first on launch / foreground / an accepted auth
/// relay, same triggers as the other two queues.
///
/// Retries are DELIBERATELY unbounded, matching the other two queues and NOT
/// the bounded-ledger design `fix-475-queue-poison`'s review (finding F11)
/// found unsafe: a counter that advances on transport-only or stale-auth
/// failures permanently quarantines data that was never actually rejected —
/// worse than the outage it exists to survive, because connectivity
/// returning fixes an unbounded retry but does nothing for a quarantine.
/// `drainPass` below `break`s the whole loop on ANY failure (network or
/// auth) and tries again next drain, with no per-item failure count at all —
/// the same shape `OfflineQueue`/`PendingSessionQueue` already use in this
/// codebase, which never grew that ledger in the first place.
actor PendingRecordingQueue {
    static let shared = PendingRecordingQueue()

    private var drainState = CoalescingDrain()
    private let uploader: TindeqRecordingUploading
    /// Test seam only — `nil` in production, which resolves against the real
    /// `Documents` directory below. A test passes a scratch directory so
    /// nothing here ever touches the real device/simulator filesystem.
    private let baseDirOverride: URL?

    init(uploader: TindeqRecordingUploading = RepoRecordingUploader(), baseDir: URL? = nil) {
        self.uploader = uploader
        self.baseDirOverride = baseDir
    }

    private var pendingDir: URL {
        let docs = baseDirOverride
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("pending-recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Count of items pending for the currently signed-in account, PLUS any
    /// item stranded while nobody is signed in (issue #189) — see
    /// `OfflineQueue.pendingCount`'s doc for the full reasoning; identical
    /// here.
    func pendingCount() -> Int {
        let currentUserId = WatchSessionStore.shared.userId
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
        let count = files.filter { file in
            guard
                let data = try? Data(contentsOf: file),
                let pending = try? decoder.decode(PendingTindeqRecording.self, from: data)
            else { return true } // unreadable: retained and reported until a later build can decode it
            return shouldDrain(itemUserId: pending.enqueuedUserId, currentUserId: currentUserId)
                || currentUserId == nil
        }.count
        // Publish for the sync-readable stamp (#21): reading this actor is an
        // await, which the WatchConnectivity send paths can't do.
        PendingSyncCache.shared.record(count, for: .tindeqRecordings)
        return count
    }

    /// Persist the recording and return as soon as it's on disk — the upload
    /// runs in the background (the queue retries until it lands). If
    /// persistence fails, keep the in-memory row alive long enough to attempt
    /// the idempotent upload directly; only failure of both paths is `.lost`.
    func enqueue(_ pending: PendingTindeqRecording) async -> QueuePersistOutcome {
        var pending = pending
        // Stamp which account is signed in right now (issue #158) — the
        // relayed access token's `sub` claim, read synchronously from the
        // Keychain cache (#265). Checked back in drain().
        pending.enqueuedUserId = WatchSessionStore.shared.userId

        switch PendingQueuePolicy.actionAfterPersist(persist(pending)) {
        case .drainQueued:
            Task { await drain() }
            return .queued
        case .uploadDirect:
            do {
                try await uploader.upload(pending.row)
                return PendingQueuePolicy.outcomeAfterDirectUpload(succeeded: true)
            } catch {
                return PendingQueuePolicy.outcomeAfterDirectUpload(succeeded: false)
            }
        }
    }

    /// #486 review F5: encoding failure is a programmer error no eviction can
    /// fix, so it's kept out of the retry loop below — only the actual disk
    /// WRITE gets the eviction treatment.
    private func persist(_ pending: PendingTindeqRecording) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = pendingDir.appendingPathComponent("\(pending.row.id.uuidString).json")
        let persisted: Bool
        if let data = try? encoder.encode(pending) {
            persisted = writeWithEviction(data, to: url)
        } else {
            persisted = false
        }
        _ = pendingCount() // refresh the reported depth (#21)
        Task { @MainActor in WatchBuild.reportQueueStatus() }
        return persisted
    }

    /// #486 review F5: a refused write (disk full) is retried after dropping
    /// the OLDEST other queued file, repeatedly, down to this new entry
    /// alone — the same "the new recording wins" policy `recordingQueue.ts`
    /// decided under CLAUDE.md #264 for the web queue: the new recording is
    /// the rep the user just pulled and is still thinking about, while a
    /// queued entry has by definition already failed to sync at least once.
    /// Before this, a full `Documents` volume destroyed the NEWEST rep (via
    /// the `.uploadDirect` → `.lost` fallback in `enqueue`) while every
    /// older, already-failing entry survived untouched — the inverse of that
    /// decision.
    private func writeWithEviction(_ data: Data, to url: URL) -> Bool {
        while true {
            do {
                try data.write(to: url, options: .atomic)
                return true
            } catch {
                guard let oldest = oldestOtherFile(excluding: url) else { return false }
                try? FileManager.default.removeItem(at: oldest)
            }
        }
    }

    private func oldestOtherFile(excluding url: URL) -> URL? {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: pendingDir, includingPropertiesForKeys: [.creationDateKey]
        )) ?? [])
            .filter { $0.pathExtension == "json" && $0 != url }
        guard !files.isEmpty else { return nil }
        return files.min { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return l < r
        }
    }

    func drain() async {
        guard drainState.request() == .start else { return }
        // request() marks the actor as running before this first suspension.
        repeat {
            await drainPass()
        } while drainState.completePass() == .rerun
    }

    private func drainPass() async {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: pendingDir, includingPropertiesForKeys: [.creationDateKey]
        )) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return l < r
            }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files {
            guard
                let data = try? Data(contentsOf: file),
                let pending = try? decoder.decode(PendingTindeqRecording.self, from: data)
            else {
                // Never delete an unreadable or undecodable value (#287).
                // It stays counted/published through PendingSyncCache and a
                // later compatible build gets another chance to recover it.
                continue
            }
            // Read fresh right before each file's check, not once before the
            // loop (issue #158) — this is a non-@MainActor actor and `await`
            // below is a suspension point, so a concurrent account switch
            // could otherwise go unnoticed for the rest of the pass and let
            // a recording queued under Account A upload under Account B.
            let currentUserId = WatchSessionStore.shared.userId
            guard shouldDrain(itemUserId: pending.enqueuedUserId, currentUserId: currentUserId) else {
                // Queued under a different account (or nobody's signed in):
                // leave the file on disk untouched and keep checking the
                // rest — this is not a network/auth error, so don't `break`.
                continue
            }
            do {
                try await uploader.upload(pending.row)
                try? FileManager.default.removeItem(at: file)
            } catch {
                break // no network (or auth) — stop, retry next drain
            }
        }
        _ = pendingCount() // refresh the reported depth (#21)
        await MainActor.run { WatchBuild.reportQueueStatus() }
    }
}
