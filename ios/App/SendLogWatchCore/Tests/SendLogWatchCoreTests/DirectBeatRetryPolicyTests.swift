import XCTest
import SendLogWatchCore

final class DirectBeatRetryPolicyTests: XCTestCase {
    func testTelemetryIsNeverRetried() {
        XCTAssertFalse(
            DirectBeatRetryPolicy.shouldRetry(
                event: .telemetry, consecutiveFailures: 0, retryInFlight: false
            )
        )
    }

    func testFirstDiscreteFailureRetries() {
        XCTAssertTrue(
            DirectBeatRetryPolicy.shouldRetry(
                event: .phase, consecutiveFailures: 0, retryInFlight: false
            )
        )
        XCTAssertTrue(
            DirectBeatRetryPolicy.shouldRetry(
                event: .start, consecutiveFailures: 0, retryInFlight: false
            )
        )
        XCTAssertTrue(
            DirectBeatRetryPolicy.shouldRetry(
                event: .end, consecutiveFailures: 0, retryInFlight: false
            )
        )
    }

    func testCapIsExclusive() {
        // `consecutiveFailures < max` means the cap is reached AT max, never
        // exceeded — a sustained outage stops after exactly `max` retries.
        for count in 0..<DirectBeatRetryPolicy.maxConsecutiveRetries {
            XCTAssertTrue(
                DirectBeatRetryPolicy.shouldRetry(
                    event: .count, consecutiveFailures: count, retryInFlight: false
                )
            )
        }
        XCTAssertFalse(
            DirectBeatRetryPolicy.shouldRetry(
                event: .count,
                consecutiveFailures: DirectBeatRetryPolicy.maxConsecutiveRetries,
                retryInFlight: false
            )
        )
    }

    func testRetryInFlightDedupes() {
        XCTAssertFalse(
            DirectBeatRetryPolicy.shouldRetry(
                event: .phase, consecutiveFailures: 0, retryInFlight: true
            )
        )
    }
}
