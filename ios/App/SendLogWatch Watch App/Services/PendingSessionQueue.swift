import Foundation

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

    func pendingCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" }.count ?? 0
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
            do {
                try await Repo.logTindeqSession(session)
                try? FileManager.default.removeItem(at: file)
            } catch {
                break // no network (or auth) — stop, retry next drain
            }
        }
    }
}
