import Foundation

/// The watch's offline upload queues, as far as the queue-depth report is
/// concerned (#21). All three are persist-first disk queues drained
/// oldest-first, and the watch's own Home screen already shows their sum —
/// reporting the same sum keeps the phone's answer and the watch's answer the
/// same number.
public enum PendingSyncQueue: String, Sendable, CaseIterable {
    /// The workouts queue (`OfflineQueue`) — climb workouts.
    case workouts
    /// `PendingSessionQueue` — end-of-gauge Tindeq sessions.
    case tindeqSessions
    /// `PendingRecordingQueue` — individual Tindeq force recordings (#486).
    case tindeqRecordings
    /// `LiveWorkoutTerminalRetry` (#531/#549) — the single durable fallback
    /// row for a failed terminal `live_workouts` upsert. Unlike the other
    /// three (many-file, disk-directory queues with a quarantine concept),
    /// this is a single JSON file holding at most one row and never
    /// quarantines anything — it still reports 0 for both quarantine slots
    /// every refresh so `quarantinedTotal`/`quarantinedStuckTotal` don't
    /// permanently stick at nil once this case exists.
    case liveWorkoutTerminal
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
/// Every total is nil until EVERY queue has published its slot (#491). Two
/// honest-states rules compose here: "we have never counted" must not be
/// reported as "zero pending" (a watch that has never looked at its queues
/// must not read as a healthy empty one), and — the #491 acceptance — a sum
/// over only the queues that happened to report must not be presented as the
/// queue depth, because it under-reports SILENTLY: a dropped source reads as
/// zero, not as an error. (That was live, not hypothetical: the exact
/// `async let` hunk feeding this cache conflicted when #475 and #486
/// composed, and taking either side alone lost a queue with no compile error
/// and no wrong-looking number.) A partial sum therefore reads as nil — "not
/// reported" — which the phone already renders honestly; the launch/foreground
/// refresh (`WatchBuild.refreshAndReportQueueStatus`) counts every queue, so
/// the window where a total is nil is momentary, not a steady state.
public final class PendingSyncCache: @unchecked Sendable {
    public static let shared = PendingSyncCache()

    private let lock = NSLock()
    private var counts: [PendingSyncQueue: Int] = [:]
    private var unscopedPending: [PendingSyncQueue: Int] = [:]
    private var unscopedQuarantined: [PendingSyncQueue: Int] = [:]
    private var quarantined: [PendingSyncQueue: Int] = [:]
    private var quarantinedStuck: [PendingSyncQueue: Int] = [:]

    public init() {}

    public func record(_ count: Int, for queue: PendingSyncQueue) {
        lock.lock()
        defer { lock.unlock() }
        counts[queue] = max(0, count)
    }

    /// Sum across the queues, or nil unless every queue has reported (#491 —
    /// see the type doc: a partial sum silently under-reports, and nil is the
    /// honest "not reported" the phone already knows how to render).
    public var total: Int? {
        lock.lock()
        defer { lock.unlock() }
        return sumIfComplete(counts)
    }

    /// Ownerless legacy rows are deliberately not included in `total`: they
    /// cannot be safely uploaded under whichever account happens to be
    /// signed in. They remain a separately reported diagnostic bucket so
    /// "unknown owner" is visible and is never mistaken for zero.
    public func recordUnscopedPending(_ count: Int, for queue: PendingSyncQueue) {
        lock.lock()
        defer { lock.unlock() }
        unscopedPending[queue] = max(0, count)
    }

    public func recordUnscopedQuarantined(_ count: Int, for queue: PendingSyncQueue) {
        lock.lock()
        defer { lock.unlock() }
        unscopedQuarantined[queue] = max(0, count)
    }

    /// Sum of decoded ownerless and undecodable rows across both queue
    /// surfaces, or nil until every queue has reported both buckets.
    public var unscopedTotal: Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let pending = sumIfComplete(unscopedPending),
              let quarantined = sumIfComplete(unscopedQuarantined) else { return nil }
        return pending + quarantined
    }

    /// Count of items each queue has quarantined (#475, generalized to every
    /// queue by #491): landed on disk, but taken off the drain path — either
    /// a proven-permanent DB constraint violation, or (#475 F3/F12) an
    /// unrecognized error that failed too many consecutive SERVER-EVALUATED
    /// passes and is now waiting on a long backoff for another attempt
    /// (`QuarantineReason`; `quarantinedStuckTotal` below is the subset in
    /// that second, non-terminal state). Deliberately kept OUT of `total` —
    /// folding a quarantined item into the "pending" sum would read to the
    /// user as "will sync", which the CLAUDE.md #264 rule forbids for
    /// anything that isn't actually queued to sync right now. Per-queue slots
    /// (#491): with all three queues quarantining, a single shared count
    /// would let each queue's report stomp the others'.
    public func recordQuarantined(_ count: Int, for queue: PendingSyncQueue) {
        lock.lock()
        defer { lock.unlock() }
        quarantined[queue] = max(0, count)
    }

    /// Same completeness rule as `total`: nil unless every queue has
    /// reported its quarantine slot.
    public var quarantinedTotal: Int? {
        lock.lock()
        defer { lock.unlock() }
        return sumIfComplete(quarantined)
    }

    /// Subset of `quarantinedTotal` whose `QuarantineReason` is
    /// `.stuckRetrying` (#475 F13) — items that WILL be automatically
    /// re-attempted after a backoff, as opposed to the proven-permanent
    /// `.schemaRejection` remainder (`quarantinedTotal - quarantinedStuckTotal`).
    /// Reported separately so the phone can tell the user the true,
    /// different fact about each kind rather than one sentence that is only
    /// accurate for one of them.
    public func recordQuarantinedStuck(_ count: Int, for queue: PendingSyncQueue) {
        lock.lock()
        defer { lock.unlock() }
        quarantinedStuck[queue] = max(0, count)
    }

    public var quarantinedStuckTotal: Int? {
        lock.lock()
        defer { lock.unlock() }
        return sumIfComplete(quarantinedStuck)
    }

    private func sumIfComplete(_ slots: [PendingSyncQueue: Int]) -> Int? {
        guard PendingSyncQueue.allCases.allSatisfy({ slots[$0] != nil }) else { return nil }
        return slots.values.reduce(0, +)
    }

    /// Test seam — production has one process-wide cache.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        counts = [:]
        unscopedPending = [:]
        unscopedQuarantined = [:]
        quarantined = [:]
        quarantinedStuck = [:]
    }
}
