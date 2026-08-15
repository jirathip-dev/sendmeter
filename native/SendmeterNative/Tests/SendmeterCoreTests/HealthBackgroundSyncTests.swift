import XCTest
@testable import SendmeterCore

final class HealthBackgroundSyncTests: XCTestCase {
    // MARK: Observed types

    func testObservedIdentifiersAreExactlyTheFourBackgroundDeliveryTypes() {
        XCTAssertEqual(
            HealthObserverTypes.observedIdentifiers,
            [
                "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
                "HKQuantityTypeIdentifierRestingHeartRate",
                "HKQuantityTypeIdentifierRespiratoryRate",
                "HKCategoryTypeIdentifierSleepAnalysis",
            ]
        )
        XCTAssertEqual(HealthObserverTypes.observedIdentifiers.count, 4)
        XCTAssertEqual(
            Set(HealthObserverTypes.observedIdentifiers).count,
            HealthObserverTypes.observedIdentifiers.count,
            "observed identifiers must not contain duplicates"
        )
    }

    // MARK: ReadinessRecomputeGate

    func testGateStartsWhenIdleAndCoalescesConcurrentFires() {
        var gate = ReadinessRecomputeGate()
        XCTAssertEqual(gate.request(), .start)
        XCTAssertTrue(gate.isRunning)

        // A storm of concurrent fires (foreground sync + background observer
        // wakes) collapses to at most one follow-up.
        for _ in 0..<20 {
            XCTAssertEqual(gate.request(), .queued)
        }

        XCTAssertEqual(gate.complete(), .rerun)
        XCTAssertTrue(gate.isRunning)
        XCTAssertEqual(gate.complete(), .idle)
        XCTAssertFalse(gate.isRunning)
    }

    func testGateRunsAtMostOneFollowUpPass() {
        var gate = ReadinessRecomputeGate()
        XCTAssertEqual(gate.request(), .start)
        // A background fire lands while the foreground pass is running.
        XCTAssertEqual(gate.request(), .queued)

        var passes = 0
        while true {
            passes += 1
            XCTAssertTrue(passes <= 2, "a single owner flight must never run a third pass")
            let completion = gate.complete()
            if completion == .idle { break }
            for _ in 0..<5 {
                XCTAssertEqual(gate.request(), .queued)
            }
        }
        XCTAssertEqual(passes, 2)
        XCTAssertFalse(gate.isRunning)
    }

    func testCancelDropsQueuedFollowUpAndAllowsFreshStart() {
        var gate = ReadinessRecomputeGate()
        XCTAssertEqual(gate.request(), .start)
        XCTAssertEqual(gate.request(), .queued)

        gate.cancel()
        XCTAssertFalse(gate.isRunning)
        XCTAssertEqual(gate.request(), .start)
        XCTAssertEqual(gate.complete(), .idle)
    }
}
