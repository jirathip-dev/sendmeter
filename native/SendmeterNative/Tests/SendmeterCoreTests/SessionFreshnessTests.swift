import XCTest
@testable import SendmeterCore

final class SessionFreshnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let window = SessionFreshness.defaultSafetyWindow

    func testFreshTokenRequiresNoRefresh() {
        let expires = now.timeIntervalSince1970 + 300
        XCTAssertFalse(SessionFreshness.needsRefresh(expiresAt: expires, now: now))
        XCTAssertTrue(SessionFreshness.isFresh(expiresAt: expires, now: now))
    }

    func testExpiredTokenRequiresRefresh() {
        let expires = now.timeIntervalSince1970 - 1
        XCTAssertTrue(SessionFreshness.needsRefresh(expiresAt: expires, now: now))
        XCTAssertFalse(SessionFreshness.isFresh(expiresAt: expires, now: now))
    }

    func testTokenInsideSafetyWindowRequiresRefresh() {
        let expires = now.timeIntervalSince1970 + window - 1
        XCTAssertTrue(SessionFreshness.needsRefresh(expiresAt: expires, now: now))
    }

    func testTokenAtSafetyWindowBoundaryRequiresRefresh() {
        // At exactly `now + window` the token is inside the window — refresh.
        let expires = now.timeIntervalSince1970 + window
        XCTAssertTrue(SessionFreshness.needsRefresh(expiresAt: expires, now: now))
    }

    func testTokenJustBeyondSafetyWindowIsFresh() {
        let expires = now.timeIntervalSince1970 + window + 1
        XCTAssertFalse(SessionFreshness.needsRefresh(expiresAt: expires, now: now))
        XCTAssertTrue(SessionFreshness.isFresh(expiresAt: expires, now: now))
    }

    func testNilExpiryRequiresRefresh() {
        XCTAssertTrue(SessionFreshness.needsRefresh(expiresAt: nil, now: now))
        XCTAssertFalse(SessionFreshness.isFresh(expiresAt: nil, now: now))
    }

    func testCustomSafetyWindowIsRespected() {
        // A 5s window: a token 10s away is outside the window (fresh)…
        XCTAssertFalse(
            SessionFreshness.needsRefresh(
                expiresAt: now.timeIntervalSince1970 + 10,
                now: now,
                safetyWindow: 5
            )
        )
        // …but a token 3s away is inside it (needs refresh).
        XCTAssertTrue(
            SessionFreshness.needsRefresh(
                expiresAt: now.timeIntervalSince1970 + 3,
                now: now,
                safetyWindow: 5
            )
        )
    }
}
