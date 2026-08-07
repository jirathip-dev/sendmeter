import Foundation
import SendLogWatchCore
import WatchConnectivity

/// This install's own version + build plus its offline-queue depth, stamped
/// onto every message the watch already sends to the phone (#228, #21).
///
/// The watch app updates from TestFlight independently of the phone app, so a
/// phone on the current build can be paired with a watch several builds back —
/// which is how a pre-#208 watch kept revoking a fixed phone's session family
/// with nobody able to see it. The queue depth rides the same channel for the
/// same reason: a workout stuck in `OfflineQueue` is invisible until someone
/// picks the watch up. Nothing new is sent — the live-workout beat, the
/// live-force beat and the `requestSession` ask each gain a few fields, and an
/// unknown value is simply left off.
enum WatchBuild {
    static let identity = BuildIdentity(infoDictionary: Bundle.main.infoDictionary)
    private static let reportLock = NSLock()
    private nonisolated(unsafe) static var lastReportedQueueTotal: Int?
    /// #475 F1: tracked separately from `lastReportedQueueTotal` — a change
    /// in ONLY the quarantine count (nothing pending changed) must still
    /// trigger a report, or a workout that gets quarantined while the
    /// pending total happens to stay flat would never reach the phone.
    private nonisolated(unsafe) static var lastReportedQuarantinedTotal: Int?
    /// #475 F13: tracked separately again — a bundle moving between
    /// `.schemaRejection` and `.stuckRetrying` (the F12 resurrection path)
    /// can change this subset while the overall quarantined total stays the
    /// same number, and the phone needs to hear about that too.
    private nonisolated(unsafe) static var lastReportedQuarantinedStuckTotal: Int?

    static func stamp(_ message: [String: Any]) -> [String: Any] {
        // Cached (see `PendingSyncCache`) because this is a synchronous send
        // path — the queues themselves are actors, and the force beat runs at
        // ~2 Hz. nil until a queue has been counted, which reports honestly as
        // "not reported" rather than as an empty queue.
        WatchBuildReport.stamped(
            message,
            with: identity,
            pendingSync: PendingSyncCache.shared.total,
            quarantinedSync: PendingSyncCache.shared.quarantinedTotal,
            quarantinedStuckSync: PendingSyncCache.shared.quarantinedStuckTotal
        )
    }

    /// An explicit authoritative report, including zero, after queue state
    /// changes. Piggyback-only diagnostics left an old nonzero value on the
    /// phone when the newly installed watch had not yet sent another beat.
    @MainActor
    static func reportQueueStatus() {
        guard let total = PendingSyncCache.shared.total,
              WCSession.isSupported(),
              WCSession.default.activationState == .activated
        else { return }
        let quarantined = PendingSyncCache.shared.quarantinedTotal
        let quarantinedStuck = PendingSyncCache.shared.quarantinedStuckTotal
        reportLock.lock()
        guard total != lastReportedQueueTotal
            || quarantined != lastReportedQuarantinedTotal
            || quarantinedStuck != lastReportedQuarantinedStuckTotal
        else {
            reportLock.unlock()
            return
        }
        lastReportedQueueTotal = total
        lastReportedQuarantinedTotal = quarantined
        lastReportedQuarantinedStuckTotal = quarantinedStuck
        reportLock.unlock()
        let message = stamp(["kind": "queueStatus"])
        // Guaranteed messages are enqueued synchronously in count order. An
        // asynchronous failure fallback could otherwise enqueue old count 1
        // after newer count 0 and make the phone regress to stale state.
        WCSession.default.transferUserInfo(message)
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil)
        }
    }

    /// Every queue whose depth the phone should hear about (#491). A new
    /// queue MUST be added here (and get its own `PendingSyncQueue` case) —
    /// two structural guards replace the old "all four `async let`s must
    /// stay in the tuple" comment, which was load-bearing exactly once and
    /// then nearly lost in a merge: `PendingSyncCache` now refuses to report
    /// a total until EVERY `PendingSyncQueue` case has published (a dropped
    /// source reads as "not reported", never as an empty queue), and
    /// `WatchQueueReportingTests` pins that this registry covers every case.
    static let reportingQueues: [any QueueDepthReporting] = [
        OfflineQueue.shared,
        PendingSessionQueue.shared,
        PendingRecordingQueue.shared,
    ]

    /// Count every queue's totals first so a fresh install reports an honest
    /// zero rather than leaving `PendingSyncCache` unknown — quarantine
    /// included (#475 F1), since this runs independently of (and
    /// concurrently with) the per-queue `drain()`s at launch (see
    /// `SendLogWatchApp.swift`) and can't assume a drain pass has already
    /// populated it.
    static func refreshAndReportQueueStatus() async {
        await withTaskGroup(of: Void.self) { group in
            for queue in reportingQueues {
                group.addTask { await queue.refreshReportedCounts() }
            }
        }
        await MainActor.run { reportQueueStatus() }
    }
}
