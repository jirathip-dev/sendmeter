import Foundation
import SendLogWatchCore
import Supabase

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

    private var pendingDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
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
                try await Repo.insertTindeqRecording(pending.row)
                return PendingQueuePolicy.outcomeAfterDirectUpload(succeeded: true)
            } catch {
                return PendingQueuePolicy.outcomeAfterDirectUpload(succeeded: false)
            }
        }
    }

    private func persist(_ pending: PendingTindeqRecording) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = pendingDir.appendingPathComponent("\(pending.row.id.uuidString).json")
        let persisted: Bool
        do {
            let data = try encoder.encode(pending)
            try data.write(to: url, options: .atomic)
            persisted = true
        } catch {
            persisted = false
        }
        _ = pendingCount() // refresh the reported depth (#21)
        Task { @MainActor in WatchBuild.reportQueueStatus() }
        return persisted
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
                try await Repo.insertTindeqRecording(pending.row)
                try? FileManager.default.removeItem(at: file)
            } catch {
                break // no network (or auth) — stop, retry next drain
            }
        }
        _ = pendingCount() // refresh the reported depth (#21)
        await MainActor.run { WatchBuild.reportQueueStatus() }
    }
}
