import Foundation
import XCTest
@testable import SendmeterCore

/// #964 round 2 — the BASE red leg (committed as evidence, NOT part of the
/// lane's shipped suite).
///
/// This file characterizes the behaviour at the lane's base sha
/// (`33664129d0d36658032a1f61858735612ea63517`) — the literal "before the
/// fix". It is GREEN at base and RED at the fixed head, which is what proves
/// the fix changed the behaviour rather than merely adding assertions:
///
/// * a `DeltaReadError` (the delta reader failing closed on a launch-path
///   data load) classified as `.unknown` — the copy the owner's device showed
///   on every cold start;
/// * a `URLError` code the taxonomy does not name (e.g. `badServerResponse`)
///   classified as `.unknown` for the same reason;
/// * a cache that could not be prepared at launch (`CacheUnavailableReason`)
///   classified as `.unknown`.
///
/// The head's own tests assert the opposite of every expectation here.
///
///   swift test --package-path native/SendmeterNative --filter Issue964bBaseRedTests
final class Issue964bBaseRedTests: XCTestCase {
    func testBaseDeltaReadFailureIsTheGenericFallback() {
        let failures: [DeltaReadError] = [
            .outOfOrderPage,
            .cursorDidNotAdvance,
            .pageBudgetExhausted(pageLimit: 64)
        ]
        for error in failures {
            XCTAssertEqual(
                UserFacingError.classification(for: error),
                .unknown,
                "base behaviour: the delta reader's fail-closed error had no class"
            )
            XCTAssertEqual(
                UserFacingError.message(for: error),
                "Something went wrong while completing that. Try again."
            )
        }
    }

    func testBaseUnnamedTransportCodeIsTheGenericFallback() {
        XCTAssertEqual(
            UserFacingError.classification(for: URLError(.badServerResponse)),
            .unknown,
            "base behaviour: an unnamed URLError code collapsed into the fallback"
        )
        XCTAssertEqual(
            UserFacingError.message(for: URLError(.badServerResponse)),
            UserFacingError.message(for: .unknown)
        )
    }

    func testBaseCachePreparationFailureIsTheGenericFallback() {
        XCTAssertEqual(
            UserFacingError.classification(for: CacheUnavailableReason.noSupportDirectory),
            .unknown,
            "base behaviour: a cache that could not be prepared had no class"
        )
    }
}
