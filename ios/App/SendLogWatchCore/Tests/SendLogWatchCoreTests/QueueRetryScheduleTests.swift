import XCTest
import SendLogWatchCore

/// Issue #472b: `OfflineQueue.drain()` used to retry only on scenePhase
/// `.active`, an accepted relay, or a fresh `enqueue()` — a watch that failed
/// a drain and then sat idle waited indefinitely for one of those. These pin
/// the pure delay schedule the actor's backoff timer consumes; the
/// production wiring (does a stalled drain actually schedule one, with no
/// external trigger) is pinned separately in `OfflineQueueTests`, which is
/// the only place that's writable per the #475 review's F11 finding on this
/// same seam.
final class QueueRetryScheduleTests: XCTestCase {
    func testFirstStallUsesTheBaseDelay() {
        XCTAssertEqual(QueueRetrySchedule.delay(forConsecutiveStalls: 1), QueueRetrySchedule.baseDelayS)
    }

    func testDelayGrowsWithConsecutiveStalls() {
        let d1 = QueueRetrySchedule.delay(forConsecutiveStalls: 1)
        let d2 = QueueRetrySchedule.delay(forConsecutiveStalls: 2)
        let d3 = QueueRetrySchedule.delay(forConsecutiveStalls: 3)
        XCTAssertLessThan(d1, d2)
        XCTAssertLessThan(d2, d3)
    }

    /// The growth must stop, not the retrying itself — a huge stall count
    /// (the exact shape of a sustained outage) must still yield a finite,
    /// bounded delay rather than growing without limit.
    func testDelayCapsAtMaxDelayNoMatterHowManyStalls() {
        XCTAssertEqual(QueueRetrySchedule.delay(forConsecutiveStalls: 6), QueueRetrySchedule.maxDelayS)
        XCTAssertEqual(QueueRetrySchedule.delay(forConsecutiveStalls: 7), QueueRetrySchedule.maxDelayS)
        XCTAssertEqual(QueueRetrySchedule.delay(forConsecutiveStalls: 1000), QueueRetrySchedule.maxDelayS)
    }

    func testDelayNeverExceedsMaxDelay() {
        for stalls in 1...200 {
            XCTAssertLessThanOrEqual(QueueRetrySchedule.delay(forConsecutiveStalls: stalls), QueueRetrySchedule.maxDelayS)
        }
    }

    func testDelayIsMonotonicNonDecreasing() {
        var previous: TimeInterval = 0
        for stalls in 1...20 {
            let delay = QueueRetrySchedule.delay(forConsecutiveStalls: stalls)
            XCTAssertGreaterThanOrEqual(delay, previous)
            previous = delay
        }
    }
}
