import Foundation
import SendLogWatchCore

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
}
