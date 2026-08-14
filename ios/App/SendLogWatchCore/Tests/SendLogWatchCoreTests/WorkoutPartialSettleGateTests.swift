import XCTest
import SendLogWatchCore

/// #615: the settle gate between the in-flight mid-workout partial flush and
/// the final bundle upload — the wait #477 required at End now lives on the
/// upload path instead, so the durable queue commit and the phone
/// notification are never parked behind a network call.
final class WorkoutPartialSettleGateTests: XCTestCase {
    func testHoldNilSettlesImmediately() async {
        let gate = WorkoutPartialSettleGate()
        gate.hold(nil)
        // Would hang forever on a broken gate; the XCTest timeout is the
        // only bound needed.
        await gate.waitForCurrent()
    }

    func testWaiterBlocksUntilHeldTaskCompletes() async {
        let gate = WorkoutPartialSettleGate()
        let released = AsyncGate()
        let task = Task { await released.wait() }
        gate.hold(task)
        let fulfilled = FulfillmentFlag()
        let waiter = Task {
            await gate.waitForCurrent()
            fulfilled.mark()
        }
        // Give the waiter a chance to start blocking.
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(fulfilled.isSet, "waiter must block until the partial settles")
        await released.release()
        await waiter.value
        XCTAssertTrue(fulfilled.isSet)
    }

    func testReholdDoesNotDisturbPriorWaiter() async {
        let gate = WorkoutPartialSettleGate()
        let oldTaskGate = AsyncGate()
        let newTaskGate = AsyncGate()
        let oldTask = Task { await oldTaskGate.wait() }
        gate.hold(oldTask)
        let oldWaiter = Task { await gate.waitForCurrent() }
        try? await Task.sleep(for: .milliseconds(50))
        // A new run's stop re-holds with its own partial; the old waiter
        // still awaits the OLD task (captured at wait time).
        let newTask = Task { await newTaskGate.wait() }
        gate.hold(newTask)
        await newTaskGate.release()
        // Release the old task: the old waiter must return now.
        await oldTaskGate.release()
        await oldWaiter.value
    }
}

/// A test-side one-shot gate the held tasks block on.
private actor AsyncGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters = []
        for w in pending { w.resume() }
    }
}

/// Thread-safe fulfillment flag.
private final class FulfillmentFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _isSet = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isSet
    }
    func mark() {
        lock.lock()
        _isSet = true
        lock.unlock()
    }
}
