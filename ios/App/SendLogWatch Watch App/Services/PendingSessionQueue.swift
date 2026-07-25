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

    private var draining = false

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
        let currentUserId = SupabaseService.client.auth.currentSession?.user.id
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
        return files.filter { file in
            guard
                let data = try? Data(contentsOf: file),
                let session = try? decoder.decode(PendingTindeqSession.self, from: data)
            else { return true } // unreadable: still counts until drain() cleans it up
            return shouldDrain(itemUserId: session.enqueuedUserId, currentUserId: currentUserId)
                || currentUserId == nil
        }.count
    }

    /// Persist the session and return as soon as it's on disk — the upload
    /// runs in the background (the queue retries until it lands). Use this
    /// from "Log Session" so the sheet dismisses instantly instead of
    /// blocking on the network call that used to freeze mid-flight.
    func enqueue(_ session: PendingTindeqSession) {
        persist(session)
        Task { await drain() }
    }

    private func persist(_ session: PendingTindeqSession) {
        var session = session
        // Stamp which account is signed in right now (issue #158) — same
        // synchronous, non-refreshing accessor AuthManager.bootstrap() uses,
        // so this never triggers a token refresh. Checked back in drain().
        session.enqueuedUserId = SupabaseService.client.auth.currentSession?.user.id
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = pendingDir.appendingPathComponent("\(session.id.uuidString).json")
        if let data = try? encoder.encode(session) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }

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
                // unreadable file: remove so it can't wedge the queue forever
                try? FileManager.default.removeItem(at: file)
                continue
            }
            // Read fresh right before each file's check, not once before the
            // loop (issue #158) — this is a non-@MainActor actor and `await`
            // below is a suspension point, so a concurrent account switch
            // could otherwise go unnoticed for the rest of the pass and let
            // a session queued under Account A upload under Account B.
            let currentUserId = SupabaseService.client.auth.currentSession?.user.id
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
    }
}
