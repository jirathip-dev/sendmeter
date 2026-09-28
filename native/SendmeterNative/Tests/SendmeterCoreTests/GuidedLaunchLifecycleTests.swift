import Foundation
import XCTest
@testable import SendmeterCore

/// #1004 half 1: the guided-launch flag belongs to an ATTEMPT, and every
/// terminal outcome releases it. The shipped defect was a bare `Bool` set
/// before an unstructured `Task` whose resolution could never settle, leaving
/// the primary action locked with no explanation for the life of the process.
final class GuidedLaunchLifecycleTests: XCTestCase {
    private func makePreset(id: UUID = UUID(), name: String = "Max hang 7s") -> TindeqPreset {
        TindeqPreset(
            id: id,
            name: name,
            holdSeconds: 7,
            repetitions: 3,
            sets: 5,
            restBetweenRepetitionsSeconds: 60,
            restBetweenSetsSeconds: 180,
            targetPercentage: 85,
            percentageBasis: .personalRecord,
            protocolMode: .hold
        )
    }

    /// The load-bearing invariant: no outcome may leave the launch flag set.
    /// This is a closed set — a new outcome can only be added by also deciding
    /// (here) whether it releases the surface.
    func testEveryTerminalOutcomeReleasesTheInFlightFlag() {
        let outcomes: [GuidedLaunchOutcome] = [
            .launched,
            .superseded,
            .timedOut(loadFailureClass: nil),
            .timedOut(loadFailureClass: .dataUnreadable),
        ]
        for outcome in outcomes {
            var lifecycle = GuidedLaunchLifecycle()
            let attempt = lifecycle.begin(preset: makePreset())
            XCTAssertTrue(lifecycle.inFlight, "\(outcome) fixture: the attempt is in flight")

            XCTAssertTrue(lifecycle.settle(attempt, outcome: outcome))

            XCTAssertFalse(lifecycle.inFlight, "\(outcome) must not leave the launch flag set")
            XCTAssertNil(lifecycle.attemptID)
        }
    }

    func testASuccessfulLaunchLeavesNoFailureNotice() {
        var lifecycle = GuidedLaunchLifecycle()
        let preset = makePreset()
        let attempt = lifecycle.begin(preset: preset)

        lifecycle.settle(attempt, outcome: .launched)

        XCTAssertNil(lifecycle.failure)
        XCTAssertNil(lifecycle.retryPreset)
    }

    /// A deadlined resolution is the failure the user must SEE, carrying the
    /// preset the retry re-runs.
    func testADeadlineSurfacesARetryableFailureForTheAttemptedPreset() {
        var lifecycle = GuidedLaunchLifecycle()
        let preset = makePreset()
        let attempt = lifecycle.begin(preset: preset)

        lifecycle.settle(attempt, outcome: .timedOut(loadFailureClass: nil))

        XCTAssertEqual(lifecycle.failure?.preset, preset)
        XCTAssertEqual(lifecycle.failure?.isRetryable, true)
        XCTAssertEqual(lifecycle.retryPreset, preset)
        XCTAssertEqual(
            lifecycle.failure?.message,
            UserFacingError.message(for: .timeout),
            "with no recorded load failure the deadline names itself"
        )
    }

    func testADeadlineNamesTheAccountsRecordedLoadFailureFamily() {
        var lifecycle = GuidedLaunchLifecycle()
        let attempt = lifecycle.begin(preset: makePreset())

        lifecycle.settle(attempt, outcome: .timedOut(loadFailureClass: .dataUnreadable))

        XCTAssertEqual(
            lifecycle.failure?.message,
            UserFacingError.message(for: .dataUnreadable),
            "the failure copy is the recorded class's own remedy, not a generic message"
        )
    }

    /// A stale attempt's late settlement must be a no-op: it can neither clear
    /// a newer attempt's flag nor resurrect its own failure.
    func testAStaleAttemptCannotSettleTheCurrentAttempt() {
        var lifecycle = GuidedLaunchLifecycle()
        let first = lifecycle.begin(preset: makePreset(name: "First"))
        let second = lifecycle.begin(preset: makePreset(name: "Second"))

        XCTAssertFalse(lifecycle.settle(first, outcome: .launched))
        XCTAssertTrue(lifecycle.inFlight)
        XCTAssertEqual(lifecycle.attemptID, second)

        XCTAssertFalse(lifecycle.settle(first, outcome: .timedOut(loadFailureClass: nil)))
        XCTAssertNil(lifecycle.failure, "a stale attempt must not raise its own failure")

        XCTAssertTrue(lifecycle.settle(second, outcome: .launched))
        XCTAssertFalse(lifecycle.inFlight)
    }

    func testSettlingAnAlreadySettledAttemptIsANoOp() {
        var lifecycle = GuidedLaunchLifecycle()
        let attempt = lifecycle.begin(preset: makePreset())
        lifecycle.settle(attempt, outcome: .timedOut(loadFailureClass: nil))

        XCTAssertFalse(lifecycle.settle(attempt, outcome: .launched))
        XCTAssertNotNil(lifecycle.failure, "the retry affordance survives a late settle")
    }

    /// Retrying is a NEW attempt: the old notice goes away while the retry is
    /// in flight, so the surface can never show a stale failure over a fresh
    /// attempt.
    func testBeginClearsAPreviousFailureNotice() {
        var lifecycle = GuidedLaunchLifecycle()
        let attempt = lifecycle.begin(preset: makePreset())
        lifecycle.settle(attempt, outcome: .timedOut(loadFailureClass: nil))
        XCTAssertNotNil(lifecycle.failure)

        lifecycle.begin(preset: makePreset())

        XCTAssertNil(lifecycle.failure)
        XCTAssertTrue(lifecycle.inFlight)
    }
}
