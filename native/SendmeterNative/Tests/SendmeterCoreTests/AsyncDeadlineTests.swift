import Foundation
import XCTest
@testable import SendmeterCore

/// #1004: the bounded await the guided launch (and the sign-out drain) rely on
/// so a flag cannot outlive its attempt.
final class AsyncDeadlineTests: XCTestCase {
    func testWorkThatSettlesInsideTheDeadlineReturnsItsOwnValue() async {
        let outcome = await AsyncDeadline.race(timeout: 5, fallback: -1) { 7 }

        XCTAssertEqual(outcome.value, 7)
        XCTAssertFalse(outcome.timedOut)
    }

    func testWorkThatOutlivesTheDeadlineResolvesToTheFallback() async {
        let outcome = await AsyncDeadline.race(timeout: 0.05, fallback: -1) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return 7
        }

        XCTAssertEqual(outcome.value, -1, "the deadline must win over an unsettled attempt")
        XCTAssertTrue(outcome.timedOut)
    }

    func testANonPositiveDeadlineIsAnImmediateTimeout() async {
        let outcome = await AsyncDeadline.race(timeout: 0, fallback: "fallback") {
            XCTFail("a non-positive deadline must not run the work")
            return "work"
        }

        XCTAssertEqual(outcome.value, "fallback")
        XCTAssertTrue(outcome.timedOut)
    }
}
