import XCTest
@testable import SendmeterCore

final class ToastLifecycleTests: XCTestCase {
    func testActionableToastUsesWebParityFiveSecondTimeout() {
        XCTAssertEqual(ToastLifecycle.durationSeconds(hasAction: true), 5)
        XCTAssertEqual(
            ToastLifecycle.timeoutNanoseconds(hasAction: true),
            5_000_000_000
        )
    }

    func testPassiveToastKeepsTheShortTimeout() {
        XCTAssertEqual(ToastLifecycle.durationSeconds(hasAction: false), 2)
        XCTAssertEqual(
            ToastLifecycle.timeoutNanoseconds(hasAction: false),
            2_000_000_000
        )
    }

    func testAnIdenticalReplacementCannotBeDismissedByTheOldExpiryCallback() {
        let first = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let replacement = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

        XCTAssertFalse(ToastLifecycle.shouldDismiss(currentID: replacement, callbackID: first))
        XCTAssertTrue(ToastLifecycle.shouldDismiss(currentID: replacement, callbackID: replacement))
    }
}
