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
/// unknown value is simply left off. `accountUserID` is only supplied by
/// messages whose owner is known at that call site; a legacy live payload
/// must not be attributed to whichever account happens to be relayed now.
enum WatchBuild {
    static let identity = BuildIdentity(infoDictionary: Bundle.main.infoDictionary)
    private static let reportLock = NSLock()
    private nonisolated(unsafe) static var lastReportedQueueTotal: Int?
    private nonisolated(unsafe) static var lastReportedQueueUserID: UUID?
    /// Ownerless legacy rows are a separate diagnostic count. It must trigger
    /// a fresh report even when the ordinary account-owned queue totals do not
    /// move.
    private nonisolated(unsafe) static var lastReportedUnscopedTotal: Int?
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

    static func stamp(
        _ message: [String: Any],
        accountUserID: UUID? = nil
    ) -> [String: Any] {
        // Cached (see `PendingSyncCache`) because this is a synchronous send
        // path — the queues themselves are actors, and the force beat runs at
        // ~2 Hz. nil until a queue has been counted, which reports honestly as
        // "not reported" rather than as an empty queue.
        WatchBuildReport.stamped(
            message,
            with: identity,
            accountUserID: accountUserID,
            pendingSync: PendingSyncCache.shared.total,
            unscopedSync: PendingSyncCache.shared.unscopedTotal,
            quarantinedSync: PendingSyncCache.shared.quarantinedTotal,
            quarantinedStuckSync: PendingSyncCache.shared.quarantinedStuckTotal
        )
    }

    /// An explicit authoritative report, including zero, after queue state
    /// changes. Piggyback-only diagnostics left an old nonzero value on the
    /// phone when the newly installed watch had not yet sent another beat.
    @MainActor
    static func reportQueueStatus() {
        guard let accountUserID = WatchSessionStore.shared.userId,
              let total = PendingSyncCache.shared.total,
              WCSession.isSupported(),
              WCSession.default.activationState == .activated
        else { return }
        let unscoped = PendingSyncCache.shared.unscopedTotal
        let quarantined = PendingSyncCache.shared.quarantinedTotal
        let quarantinedStuck = PendingSyncCache.shared.quarantinedStuckTotal
        reportLock.lock()
        guard accountUserID != lastReportedQueueUserID
            || total != lastReportedQueueTotal
            || unscoped != lastReportedUnscopedTotal
            || quarantined != lastReportedQuarantinedTotal
            || quarantinedStuck != lastReportedQuarantinedStuckTotal
        else {
            reportLock.unlock()
            return
        }
        lastReportedQueueUserID = accountUserID
        lastReportedQueueTotal = total
        lastReportedUnscopedTotal = unscoped
        lastReportedQuarantinedTotal = quarantined
        lastReportedQuarantinedStuckTotal = quarantinedStuck
        reportLock.unlock()
        let message = WatchBuildReport.stamped(
            ["kind": "queueStatus"],
            with: identity,
            accountUserID: accountUserID,
            pendingSync: total,
            unscopedSync: unscoped,
            quarantinedSync: quarantined,
            quarantinedStuckSync: quarantinedStuck
        )
        // Guaranteed messages are enqueued synchronously in count order. An
        // asynchronous failure fallback could otherwise enqueue old count 1
        // after newer count 0 and make the phone regress to stale state.
        WCSession.default.transferUserInfo(message)
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil)
        }
    }

    /// A normal sign-out preserves durable account-owned queue files, but the
    /// phone clears its visible telemetry. Reset the de-duplication markers so
    /// a same-account re-sign-in reports the unchanged queue again.
    static func resetQueueReportState() {
        reportLock.lock()
        lastReportedQueueUserID = nil
        lastReportedQueueTotal = nil
        lastReportedUnscopedTotal = nil
        lastReportedQuarantinedTotal = nil
        lastReportedQuarantinedStuckTotal = nil
        reportLock.unlock()
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
        LiveWorkoutTerminalRetry.shared,
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
