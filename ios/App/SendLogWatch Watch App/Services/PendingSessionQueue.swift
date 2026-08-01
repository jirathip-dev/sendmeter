import Foundation
import SendLogWatchCore
import Supabase

/// Persist-first queue for the end-of-gauge-session insert (issue #144),
/// mirroring `OfflineQueue`: "Log Session" used to `try? await` the network
/// insert directly at the exact moment the user lowers their wrist — watchOS
/// then suspends the app and freezes the in-flight request, so the session
/// row (carrying the group_id every rep needs) could land minutes to hours
/// later, arriving as a loose-recordings orphan on the phone. Every tap is
/// first serialized to Documents/pending-sessions/<uuid>.json, then uploaded
/// and deleted on success. Drained oldest-first on launch / foreground.
/// Replays are safe because the upload is an idempotent upsert on the
/// client-minted session id (see `Repo.logTindeqSession`).
actor PendingSessionQueue {
    static let shared = PendingSessionQueue()

    private var drainState = CoalescingDrain()

    private var pendingDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("pending-sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Count of items pending for the currently signed-in account, PLUS any
    /// item stranded while nobody is signed in (issue #189) — otherwise
    /// Account B would see a permanently-stuck "N pending" badge for items
    /// stranded under Account A (#158), AND a session saved while signed out
    /// would show 0 pending forever, since `shouldDrain` always returns
    /// false with `currentUserId == nil`. `drain()`'s own guard is untouched
    /// (it still never uploads a mismatched or signed-out item) — widening
    /// this count is display-only.
    func pendingCount() -> Int {
        let currentUserId = WatchSessionStore.shared.userId
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
        let count = files.filter { file in
            guard
                let data = try? Data(contentsOf: file),
                let session = try? decoder.decode(PendingTindeqSession.self, from: data)
            else { return true } // unreadable: retained and reported until a later build can decode it
            return shouldDrain(itemUserId: session.enqueuedUserId, currentUserId: currentUserId)
                || currentUserId == nil
        }.count
        // Publish for the sync-readable stamp (#21): reading this actor is an
        // await, which the WatchConnectivity send paths can't do.
        PendingSyncCache.shared.record(count, for: .tindeqSessions)
        return count
    }

    /// Persist the session and return as soon as it's on disk — the upload
    /// runs in the background (the queue retries until it lands). If
    /// persistence fails, keep the in-memory session alive long enough to
    /// attempt the idempotent upload directly; only failure of both paths is
    /// `.lost`.
    func enqueue(_ session: PendingTindeqSession) async -> QueuePersistOutcome {
        var session = session
        // Stamp which account is signed in right now (issue #158) — the
        // relayed access token's `sub` claim, read synchronously from the
        // Keychain cache (#265). Checked back in drain().
        session.enqueuedUserId = WatchSessionStore.shared.userId

        switch PendingQueuePolicy.actionAfterPersist(persist(session)) {
        case .drainQueued:
            Task { await drain() }
            return .queued
        case .uploadDirect:
            do {
                try await Repo.logTindeqSession(session)
                return PendingQueuePolicy.outcomeAfterDirectUpload(succeeded: true)
            } catch {
                return PendingQueuePolicy.outcomeAfterDirectUpload(succeeded: false)
            }
        }
    }

    private func persist(_ session: PendingTindeqSession) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = pendingDir.appendingPathComponent("\(session.id.uuidString).json")
        let persisted: Bool
        do {
            let data = try encoder.encode(session)
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
                let session = try? decoder.decode(PendingTindeqSession.self, from: data)
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
            // a session queued under Account A upload under Account B.
            let currentUserId = WatchSessionStore.shared.userId
            guard shouldDrain(itemUserId: session.enqueuedUserId, currentUserId: currentUserId) else {
                // Queued under a different account (or nobody's signed in):
                // leave the file on disk untouched and keep checking the
                // rest — this is not a network/auth error, so don't `break`.
                continue
            }
            do {
                try await Repo.logTindeqSession(session)
                try? FileManager.default.removeItem(at: file)
            } catch {
                break // no network (or auth) — stop, retry next drain
            }
        }
        _ = pendingCount() // refresh the reported depth (#21)
        await MainActor.run { WatchBuild.reportQueueStatus() }
    }
}
