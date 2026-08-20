import XCTest
@testable import SendmeterCore

final class GaugeSessionTrackerTests: XCTestCase {
    func testSessionIsMintedLazilyOnFirstSave() {
        var tracker = GaugeSessionTracker()
        XCTAssertFalse(tracker.isActive)

        let first = tracker.ensureSession(now: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(tracker.isActive)
        XCTAssertEqual(first.groupID, tracker.ensureSession().groupID)
        XCTAssertEqual(tracker.ensureSession().startedAt, first.startedAt)
    }

    func testTwoNearSimultaneousSavesShareOneGroup() {
        var tracker = GaugeSessionTracker()
        let a = tracker.ensureSession()
        let b = tracker.ensureSession()
        XCTAssertEqual(a.groupID, b.groupID)
        XCTAssertEqual(a.startedAt, b.startedAt)
    }

    func testEndActiveClaimsExactlyOnce() {
        var tracker = GaugeSessionTracker()
        let session = tracker.ensureSession(now: Date(timeIntervalSince1970: 100))

        // Two concurrent end paths (Finish tap racing a disconnect effect):
        // the first call claims the session, the second sees none.
        let ended = tracker.endActive()
        XCTAssertEqual(ended?.groupID, session.groupID)
        XCTAssertNil(tracker.endActive())
        XCTAssertFalse(tracker.isActive)
    }

    func testEndActiveWithNoSessionReturnsNil() {
        var tracker = GaugeSessionTracker()
        XCTAssertNil(tracker.endActive())
    }

    func testNextSaveAfterEndMintsAFreshGroup() {
        var tracker = GaugeSessionTracker()
        let first = tracker.ensureSession()
        _ = tracker.endActive()
        let second = tracker.ensureSession()
        XCTAssertNotEqual(first.groupID, second.groupID)
    }

    func testResetDropsActiveSessionWithoutLogging() {
        var tracker = GaugeSessionTracker()
        _ = tracker.ensureSession()
        tracker.reset()
        XCTAssertFalse(tracker.isActive)
        XCTAssertNil(tracker.endActive())
    }
}

final class GaugeSessionSaveGateTests: XCTestCase {
    func testWaitForIdleReturnsImmediatelyWhenIdle() async {
        let gate = GaugeSessionSaveGate()
        await gate.waitForIdle()
        let pending = await gate.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testWaitForIdleWaitsForOutstandingSaves() async {
        let gate = GaugeSessionSaveGate()
        await gate.begin()
        await gate.begin()

        let waiting = Task { await gate.waitForIdle() }
        // Let the waiter attach.
        await Task.yield()
        await gate.finish()
        await Task.yield()
        XCTAssertTrue(waiting.isCancelled == false)
        await gate.finish()
        await waiting.value
    }

    func testBeginFinishPairKeepsGateBalanced() async {
        let gate = GaugeSessionSaveGate()
        await gate.begin()
        await gate.finish()
        await gate.waitForIdle()
        let pending = await gate.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testStaleSaveEarlyExitStillFinishesTheGate() async {
        let gate = GaugeSessionSaveGate()

        func staleSave() async -> Bool {
            await gate.begin()
            defer { Task { await gate.finish() } }
            guard false else { return false }
            return true
        }

        let result = await staleSave()
        XCTAssertFalse(result)
        await gate.waitForIdle()
        let pending = await gate.pendingCount
        XCTAssertEqual(pending, 0)
    }
}
