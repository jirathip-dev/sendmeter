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

    static func stamp(_ message: [String: Any]) -> [String: Any] {
        // Cached (see `PendingSyncCache`) because this is a synchronous send
        // path — the queues themselves are actors, and the force beat runs at
        // ~2 Hz. nil until a queue has been counted, which reports honestly as
        // "not reported" rather than as an empty queue.
        WatchBuildReport.stamped(
            message,
            with: identity,
            pendingSync: PendingSyncCache.shared.total
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
        reportLock.lock()
        guard total != lastReportedQueueTotal else {
            reportLock.unlock()
            return
        }
        lastReportedQueueTotal = total
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

    /// Count all three actors first so a fresh install reports an honest zero
    /// rather than leaving `PendingSyncCache` unknown.
    static func refreshAndReportQueueStatus() async {
        async let workouts = OfflineQueue.shared.pendingCount()
        async let sessions = PendingSessionQueue.shared.pendingCount()
        async let recordings = PendingRecordingQueue.shared.pendingCount()
        _ = await (workouts, sessions, recordings)
        await MainActor.run { reportQueueStatus() }
    }
}
