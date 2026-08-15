import XCTest
@testable import SendmeterCore

/// Mirrors `src/lib/keepAwakeCoordinator.test.ts` — the refcount semantics
/// (#493 F-E) must not drift between the web and native implementations.
@MainActor
final class KeepAwakeTests: XCTestCase {
    func testAcquireEnablesAndLastReleaseDisables() async {
        var calls: [Bool] = []
        let coordinator = KeepAwakeCoordinator { active in
            calls.append(active)
        }

        let release = coordinator.acquire()
        await coordinator.settled()
        XCTAssertEqual(calls, [true])

        release()
        await coordinator.settled()
        XCTAssertEqual(calls, [true, false])
    }

    /// The last-write-wins coordinator this replaced would have allowed sleep
    /// here — one consumer releasing the lock the other still needed.
    func testOneOfTwoHoldersReleasingDoesNotReleaseTheOthersLock() async {
        var calls: [Bool] = []
        let coordinator = KeepAwakeCoordinator { active in
            calls.append(active)
        }

        let releaseA = coordinator.acquire()
        let releaseB = coordinator.acquire()
        await coordinator.settled()
        XCTAssertEqual(calls.last, true)

        releaseA()
        await coordinator.settled()
        XCTAssertFalse(calls.contains(false))

        releaseB()
        await coordinator.settled()
        XCTAssertEqual(calls.last, false)
    }

    func testDoubleFiredReleaseIsNoOpAndCannotStealLaterLock() async {
        var calls: [Bool] = []
        let coordinator = KeepAwakeCoordinator { active in
            calls.append(active)
        }

        let releaseA = coordinator.acquire()
        releaseA()
        let releaseB = coordinator.acquire()
        await coordinator.settled()
        XCTAssertEqual(calls.last, true)

        // A releases again (e.g. a view's cleanup firing twice): B's hold
        // must survive — a second decrement would allow sleep.
        releaseA()
        await coordinator.settled()
        XCTAssertEqual(calls.last, true)

        releaseB()
        await coordinator.settled()
        XCTAssertEqual(calls.last, false)
    }

    func testSerializesRapidAcquireReleaseAcquireBurstEndingAtCurrentIntent() async {
        var calls: [Bool] = []
        var firstTransitionResume: (() -> Void)?
        let coordinator = KeepAwakeCoordinator { active in
            calls.append(active)
            if calls.count == 1 {
                await withCheckedContinuation { continuation in
                    firstTransitionResume = { continuation.resume() }
                }
            }
        }

        let releaseA = coordinator.acquire()
        await Task.yield()
        releaseA()
        _ = coordinator.acquire()
        await Task.yield()
        XCTAssertEqual(calls, [true])

        // The intermediate release was superseded while the first transition
        // was in flight; the final applied state is the newest intent (held)
        // and no stale intermediate may ever apply `false`.
        firstTransitionResume?()
        await coordinator.settled()
        XCTAssertEqual(calls.last, true)
        XCTAssertFalse(calls.contains(false))
    }

    func testAllowsSleepAfterInFlightActivationFinishesOnUnmount() async {
        var calls: [Bool] = []
        var firstTransitionResume: (() -> Void)?
        let coordinator = KeepAwakeCoordinator { active in
            calls.append(active)
            if calls.count == 1 {
                await withCheckedContinuation { continuation in
                    firstTransitionResume = { continuation.resume() }
                }
            }
        }

        let release = coordinator.acquire()
        await Task.yield()
        release()
        firstTransitionResume?()
        await coordinator.settled()

        XCTAssertEqual(calls, [true, false])
    }

    func testReassertReappliesCurrentIntent() async {
        var calls: [Bool] = []
        let coordinator = KeepAwakeCoordinator { active in
            calls.append(active)
        }

        let release = coordinator.acquire()
        await coordinator.settled()
        await coordinator.reassert()
        XCTAssertEqual(calls, [true])

        release()
        await coordinator.settled()
        await coordinator.reassert()
        XCTAssertEqual(calls.last, false)
    }

    func testHoldCountTracksHolders() {
        var calls: [Bool] = []
        let coordinator = KeepAwakeCoordinator { active in
            calls.append(active)
        }
        XCTAssertEqual(coordinator.holdCount, 0)
        let releaseA = coordinator.acquire()
        let releaseB = coordinator.acquire()
        XCTAssertEqual(coordinator.holdCount, 2)
        releaseA()
        XCTAssertEqual(coordinator.holdCount, 1)
        releaseB()
        XCTAssertEqual(coordinator.holdCount, 0)
    }
}
