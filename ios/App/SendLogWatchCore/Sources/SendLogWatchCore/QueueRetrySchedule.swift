import Foundation

// MARK: - Issue #472b — bounded backoff for a drain that stops without resolving

/// How long to wait before automatically re-attempting a drain that stopped
/// early (a `.retry` or `.needsAuthRelay` break in `OfflineQueue.drainPass`)
/// with no foreground event, no enqueue, and no accepted relay to wake it.
///
/// This is NOT `QueueRetryPolicy`, above — that ledger judges one ITEM
/// (permanent vs. transient) and is bounded in ATTEMPTS, on purpose, so an
/// unrecognized permanent error can't park the queue forever. This type
/// governs the QUEUE's own operating cadence and is deliberately bounded
/// only in DELAY, never in attempts: a version that gave up scheduling after
/// N tries would recreate the exact defect issue #472 was filed for —
/// indefinite parking with no external trigger — just with extra steps
/// first. There is no give-up state here.
///
/// What resets the growth back to `baseDelayS`: any drain pass that
/// completes WITHOUT stopping early — i.e. either every eligible item
/// uploaded, or there was nothing eligible to upload. A pass that stops on
/// `.needsAuthRelay` schedules this delay AS WELL AS asking the phone for a
/// fresh relay (`AuthManager.requestSessionFromPhone`, via `OfflineQueue`'s
/// `sessionRelay` seam) — the relay ask is the real recovery path, since
/// retrying with the same expired token just produces another 401. This
/// timer only exists to cover the case where that ask, or the phone's
/// answer to it, is lost.
public enum QueueRetrySchedule {
    public static let baseDelayS: TimeInterval = 15
    public static let maxDelayS: TimeInterval = 5 * 60

    /// `consecutiveStalls` is 1 for the first stall since the backoff last
    /// reset, 2 for the next, and so on. Doubles each step, clamped to
    /// `maxDelayS` — unbounded `consecutiveStalls` is safe: `pow` overflows
    /// to `.infinity` long before it matters, and `min` still clamps that.
    public static func delay(forConsecutiveStalls consecutiveStalls: Int) -> TimeInterval {
        precondition(consecutiveStalls >= 1, "the first stall is attempt 1, not 0")
        let steps = consecutiveStalls - 1
        return min(baseDelayS * pow(2, Double(steps)), maxDelayS)
    }
}
