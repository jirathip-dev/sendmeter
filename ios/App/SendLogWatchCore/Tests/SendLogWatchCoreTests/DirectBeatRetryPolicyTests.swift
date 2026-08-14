import XCTest
import SendLogWatchCore

final class DirectBeatRetryPolicyTests: XCTestCase {
    func testTelemetryIsNeverRetried() {
        XCTAssertFalse(
            DirectBeatRetryPolicy.shouldRetry(
                event: .telemetry, consecutiveFailures: 0, retryInFlight: false, endRetries: 0
            )
        )
    }

    func testFirstDiscreteFailureRetries() {
        XCTAssertTrue(
            DirectBeatRetryPolicy.shouldRetry(
                event: .phase, consecutiveFailures: 0, retryInFlight: false, endRetries: 0
            )
        )
        XCTAssertTrue(
            DirectBeatRetryPolicy.shouldRetry(
                event: .start, consecutiveFailures: 0, retryInFlight: false, endRetries: 0
            )
        )
    }

    func testCapIsExclusive() {
        // `consecutiveFailures < max` means the cap is reached AT max, never
        // exceeded — a sustained outage stops after exactly `max` retries.
        for count in 0..<DirectBeatRetryPolicy.maxConsecutiveRetries {
            XCTAssertTrue(
                DirectBeatRetryPolicy.shouldRetry(
                    event: .count, consecutiveFailures: count, retryInFlight: false, endRetries: 0
                )
            )
        }
        XCTAssertFalse(
            DirectBeatRetryPolicy.shouldRetry(
                event: .count,
                consecutiveFailures: DirectBeatRetryPolicy.maxConsecutiveRetries,
                retryInFlight: false,
                endRetries: 0
            )
        )
    }

    func testRetryInFlightDedupesNonTerminal() {
        XCTAssertFalse(
            DirectBeatRetryPolicy.shouldRetry(
                event: .phase, consecutiveFailures: 0, retryInFlight: true, endRetries: 0
            )
        )
    }

    // #614 review F5: the terminal transition is the one with no subsequent
    // heartbeat to recover it, so End must pre-empt a pending non-terminal
    // retry and ignore the consecutive-failure cap that an exhausted burst
    // would otherwise leave in front of it.
    func testEndRetriesEvenWithARetryInFlight() {
        XCTAssertTrue(
            DirectBeatRetryPolicy.shouldRetry(
                event: .end, consecutiveFailures: 0, retryInFlight: true, endRetries: 0
            )
        )
    }

    func testEndRetriesPastTheConsecutiveFailureCap() {
        // A count burst exhausted the cap; End must still retry.
        XCTAssertTrue(
            DirectBeatRetryPolicy.shouldRetry(
                event: .end,
                consecutiveFailures: DirectBeatRetryPolicy.maxConsecutiveRetries + 5,
                retryInFlight: false,
                endRetries: 0
            )
        )
    }

    func testEndHasItsOwnBudget() {
        for count in 0..<DirectBeatRetryPolicy.maxEndRetries {
            XCTAssertTrue(
                DirectBeatRetryPolicy.shouldRetry(
                    event: .end, consecutiveFailures: 0, retryInFlight: false, endRetries: count
                )
            )
        }
        XCTAssertFalse(
            DirectBeatRetryPolicy.shouldRetry(
                event: .end,
                consecutiveFailures: 0,
                retryInFlight: false,
                endRetries: DirectBeatRetryPolicy.maxEndRetries
            )
        )
    }

    // #614 round-2 N2: a terminal retry must still fire when the live sync
    // actor is already gone — end() tears it down fast when markEnded() 401s
    // (the #472 scenario), which is exactly when the durable fallback also
    // failed and the direct terminal beat is the last hope. Non-terminal
    // retries need the actor (nothing meaningful to re-send after teardown).
    func testOnlyTerminalMayRetryWithoutTheLiveSyncActor() {
        XCTAssertTrue(DirectBeatRetryPolicy.mayRetryWithoutLiveSync(event: .end))
        for event in [LiveMirrorEvent.start, .phase, .count, .telemetry] {
            XCTAssertFalse(
                DirectBeatRetryPolicy.mayRetryWithoutLiveSync(event: event),
                "\(event) must not re-send after the run's live sync actor is gone"
            )
        }
    }
}
