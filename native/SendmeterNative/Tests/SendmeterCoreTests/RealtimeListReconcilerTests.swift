import XCTest
@testable import SendmeterCore

final class RealtimeListReconcilerTests: XCTestCase {
    // MARK: Table → slice mapping

    func testSliceMappingMatchesWebWatchedTablesContract() {
        XCTAssertEqual(reconcileSlice(for: .sessions), .sessions)
        XCTAssertEqual(reconcileSlice(for: .tindeqRecordings), .recordings)
        XCTAssertEqual(reconcileSlice(for: .climbWorkouts), .workouts)
        XCTAssertEqual(reconcileSlice(for: .climbAttempts), .workouts)
        XCTAssertEqual(reconcileSlice(for: .healthMetrics), .health)
    }

    func testStringTableNamesMapAndUnknownIsNil() {
        XCTAssertEqual(reconcileSlice(for: "sessions"), .sessions)
        XCTAssertEqual(reconcileSlice(for: "tindeq_recordings"), .recordings)
        XCTAssertEqual(reconcileSlice(for: "climb_workouts"), .workouts)
        XCTAssertEqual(reconcileSlice(for: "climb_attempts"), .workouts)
        XCTAssertEqual(reconcileSlice(for: "health_metrics"), .health)
        XCTAssertNil(reconcileSlice(for: "live_workouts"))
        XCTAssertNil(reconcileSlice(for: "unknown_table"))
    }

    // MARK: Coalescer

    func testCoalescerUnionsSlicesWithinOneWindow() {
        let coalescer = RealtimeRefreshCoalescer(debounceIntervalMs: 400)
        coalescer.record(.sessions, atMs: 0)
        coalescer.record(.recordings, atMs: 100)
        coalescer.record(.sessions, atMs: 200)

        XCTAssertNil(coalescer.takeReadySlices(atMs: 500))
        let ready = coalescer.takeReadySlices(atMs: 600)
        XCTAssertEqual(ready, [.sessions, .recordings])
        XCTAssertFalse(coalescer.isWaiting)
        XCTAssertNil(coalescer.takeReadySlices(atMs: 999))
    }

    func testCoalescerTrailingEdgeExtendsWindow() {
        let coalescer = RealtimeRefreshCoalescer(debounceIntervalMs: 400)
        coalescer.record(.sessions, atMs: 0)
        // A burst extends the quiet window from the LAST event.
        coalescer.record(.workouts, atMs: 300)
        XCTAssertNil(coalescer.takeReadySlices(atMs: 600))
        let ready = coalescer.takeReadySlices(atMs: 700)
        XCTAssertEqual(ready, [.sessions, .workouts])
    }

    func testCoalescerRemainingMsAndReset() {
        let coalescer = RealtimeRefreshCoalescer(debounceIntervalMs: 400)
        XCTAssertEqual(coalescer.remainingMs(atMs: 100), 0)
        coalescer.record(.health, atMs: 100)
        XCTAssertEqual(coalescer.remainingMs(atMs: 100), 400)
        XCTAssertEqual(coalescer.remainingMs(atMs: 450), 50)
        XCTAssertEqual(coalescer.remainingMs(atMs: 500), 0)
        coalescer.reset()
        XCTAssertFalse(coalescer.isWaiting)
        XCTAssertNil(coalescer.takeReadySlices(atMs: 900))
    }

    func testCoalescerIdleAfterFlushAcceptsNewBurst() {
        let coalescer = RealtimeRefreshCoalescer(debounceIntervalMs: 400)
        coalescer.record(.sessions, atMs: 0)
        XCTAssertEqual(coalescer.takeReadySlices(atMs: 400), [.sessions])

        // A new event after the flush starts a fresh window — it must not be
        // lost just because the previous flush consumed the pending set.
        coalescer.record(.recordings, atMs: 500)
        XCTAssertNil(coalescer.takeReadySlices(atMs: 800))
        XCTAssertEqual(coalescer.takeReadySlices(atMs: 900), [.recordings])
    }
}
