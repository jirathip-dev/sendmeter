import Foundation
import SendLogWatchCore
import Supabase

/// Minimal offline queue for gym basements: every workout save is first
/// serialized to Documents/pending/<uuid>.json, then uploaded and deleted on
/// success. Drained serially (oldest first) on launch / foreground. Replays
/// are safe because uploads are idempotent upserts on client UUIDs.
actor OfflineQueue {
    static let shared = OfflineQueue()

    private var draining = false

    private var pendingDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Count of items pending for the currently signed-in account, PLUS any
    /// item stranded while nobody is signed in (issue #189) — otherwise
    /// Account B would see a permanently-stuck "N pending" badge for items
    /// stranded under Account A (#158), AND a workout saved while signed out
    /// would show 0 pending forever, since `shouldDrain` always returns
    /// false with `currentUserId == nil`. `drain()`'s own guard is untouched
    /// (it still never uploads a mismatched or signed-out item) — widening
    /// this count is display-only.
    func pendingCount() -> Int {
        let currentUserId = SupabaseService.auth.auth.currentSession?.user.id
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
        return files.filter { file in
            guard
                let data = try? Data(contentsOf: file),
                let bundle = try? decoder.decode(WorkoutSaveBundle.self, from: data)
            else { return true } // unreadable: still counts until drain() cleans it up
            return shouldDrain(itemUserId: bundle.enqueuedUserId, currentUserId: currentUserId)
                || currentUserId == nil
        }.count
    }

    /// Persist first, then try to upload immediately (awaits the upload).
    func enqueueAndUpload(_ bundle: WorkoutSaveBundle) async {
        persist(bundle)
        await drain()
    }

    /// Persist the bundle and return as soon as it's on disk — the upload runs
    /// in the background (the queue retries until it lands). Use this for the
    /// auto-save-on-stop flow so the UI dismisses instantly instead of blocking
    /// on the (potentially large, e.g. a 2-hour raw HR trace) network upload.
    func enqueue(_ bundle: WorkoutSaveBundle) {
        persist(bundle)
        Task { await drain() }
    }

    private func persist(_ bundle: WorkoutSaveBundle) {
        var bundle = bundle
        // Stamp which account is signed in right now (issue #158) — same
        // synchronous, non-refreshing accessor AuthManager.bootstrap() uses,
        // so this never triggers a token refresh. Checked back in drain().
        bundle.enqueuedUserId = SupabaseService.auth.auth.currentSession?.user.id
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = pendingDir.appendingPathComponent("\(bundle.workout.id.uuidString).json")
        if let data = try? encoder.encode(bundle) {
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
                let bundle = try? decoder.decode(WorkoutSaveBundle.self, from: data)
            else {
                // unreadable file: remove so it can't wedge the queue forever
                try? FileManager.default.removeItem(at: file)
                continue
            }
            // Read fresh right before each file's check, not once before the
            // loop (issue #158) — this is a non-@MainActor actor and `await`
            // below is a suspension point, so a concurrent account switch
            // could otherwise go unnoticed for the rest of the pass and let
            // a file queued under Account A upload under Account B.
            let currentUserId = SupabaseService.auth.auth.currentSession?.user.id
            guard shouldDrain(itemUserId: bundle.enqueuedUserId, currentUserId: currentUserId) else {
                // Queued under a different account (or nobody's signed in):
                // leave the file on disk untouched and keep checking the
                // rest — this is not a network/auth error, so don't `break`.
                continue
            }
            do {
                try await Repo.uploadBundle(bundle)
                try? FileManager.default.removeItem(at: file)
            } catch {
                break // no network (or auth) — stop, retry next drain
            }
        }
    }
}
