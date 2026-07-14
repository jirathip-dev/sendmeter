import Foundation

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

    func pendingCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" }.count ?? 0
    }

    /// Persist first, then try to upload immediately.
    func enqueueAndUpload(_ bundle: WorkoutSaveBundle) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = pendingDir.appendingPathComponent("\(bundle.workout.id.uuidString).json")
        if let data = try? encoder.encode(bundle) {
            try? data.write(to: url, options: .atomic)
        }
        await drain()
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
            do {
                try await Repo.uploadBundle(bundle)
                try? FileManager.default.removeItem(at: file)
            } catch {
                break // no network (or auth) — stop, retry next drain
            }
        }
    }
}
