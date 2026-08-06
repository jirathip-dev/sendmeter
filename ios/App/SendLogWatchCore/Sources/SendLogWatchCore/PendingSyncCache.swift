import Foundation

/// The watch's offline upload queues, as far as the queue-depth report is
/// concerned (#21). Both are persist-first disk queues drained oldest-first,
/// and the watch's own Home screen already shows their sum — reporting the
/// same sum keeps the phone's answer and the watch's answer the same number.
public enum PendingSyncQueue: String, Sendable, CaseIterable {
    /// `OfflineQueue` — climb workouts.
    case workouts
    /// `PendingSessionQueue` — end-of-gauge Tindeq sessions.
    case tindeqSessions
}

/// Last known depth of each queue, readable **synchronously** (#21).
///
/// The counts themselves are computed inside the queue actors, so reading one
/// is an `await` — useless on the WatchConnectivity send paths, which build a
/// message dictionary synchronously and must not be made async (the live-force
/// beat runs at ~2 Hz, and suspending the live-workout beat to stat a
/// directory would be absurd). Each queue therefore publishes its count here
/// whenever it counts, enqueues, or drains, and the stamp reads the cached
/// sum.
///
/// `total` is nil until at least one queue has published: "we have never
/// counted" must not be reported as "zero pending", or a watch that has never
/// looked at its queues would read as a healthy empty one.
public final class PendingSyncCache: @unchecked Sendable {
    public static let shared = PendingSyncCache()

    private let lock = NSLock()
    private var counts: [PendingSyncQueue: Int] = [:]
    private var quarantinedCount: Int?
    private var quarantinedStuckCount: Int?

    public init() {}

    public func record(_ count: Int, for queue: PendingSyncQueue) {
        lock.lock()
        defer { lock.unlock() }
        counts[queue] = max(0, count)
    }

    /// Sum across the queues that have reported, or nil if none has. A queue
    /// that hasn't published yet contributes nothing rather than blocking the
    /// total — the first drain publishes both anyway, and an under-count is a
    /// better failure than reporting nothing at all.
    public var total: Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !counts.isEmpty else { return nil }
        return counts.values.reduce(0, +)
    }

    /// Count of items `OfflineQueue` has quarantined (#475): landed on disk,
    /// but taken off the drain path — either a proven-permanent DB
    /// constraint violation, or (#475 F3/F12) an unrecognized error that
    /// failed too many consecutive passes and is now waiting on a long
    /// backoff for another attempt (`QuarantineReason`; `quarantinedStuckTotal`
    /// below is the subset in that second, non-terminal state). Deliberately
    /// kept OUT of `total` — folding a quarantined item into the "pending"
    /// sum would read to the user as "will sync", which the CLAUDE.md #264
    /// rule forbids for anything that isn't actually queued to sync right
    /// now. Same honest-states rule as `total`: nil until a queue has
    /// reported at least once.
    public func recordQuarantined(_ count: Int) {
        lock.lock()
        defer { lock.unlock() }
        quarantinedCount = max(0, count)
    }

    public var quarantinedTotal: Int? {
        lock.lock()
        defer { lock.unlock() }
        return quarantinedCount
    }

    /// Subset of `quarantinedTotal` whose `QuarantineReason` is
    /// `.stuckRetrying` (#475 F13) — items that WILL be automatically
    /// re-attempted after a backoff, as opposed to the proven-permanent
    /// `.schemaRejection` remainder (`quarantinedTotal - quarantinedStuckTotal`).
    /// Reported separately so the phone can tell the user the true,
    /// different fact about each kind rather than one sentence that is only
    /// accurate for one of them.
    public func recordQuarantinedStuck(_ count: Int) {
        lock.lock()
        defer { lock.unlock() }
        quarantinedStuckCount = max(0, count)
    }

    public var quarantinedStuckTotal: Int? {
        lock.lock()
        defer { lock.unlock() }
        return quarantinedStuckCount
    }

    /// Test seam — production has one process-wide cache.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        counts = [:]
        quarantinedCount = nil
        quarantinedStuckCount = nil
    }
}
