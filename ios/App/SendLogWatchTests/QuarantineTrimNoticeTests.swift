import XCTest
@testable import SendLogWatch_Watch_App

/// The reclaim notice is a durable, coalescing one-shot. Keep these tests in
/// the normal watch test target rather than relying only on the queue fixture:
/// the notice can be written by an actor and consumed later by Home after a
/// relaunch.
@MainActor
final class QuarantineTrimNoticeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = QuarantineTrimNotice.consume()
    }

    override func tearDown() {
        _ = QuarantineTrimNotice.consume()
        super.tearDown()
    }

    func testRecordSurvivesUntilTheNextAppearanceAndIsOneShot() {
        QuarantineTrimNotice.record()

        XCTAssertTrue(QuarantineTrimNotice.consume())
        XCTAssertFalse(QuarantineTrimNotice.consume())
    }

    func testRepeatedReclaimsCoalesceIntoOneDurableNotice() {
        QuarantineTrimNotice.record()
        QuarantineTrimNotice.record()

        XCTAssertTrue(QuarantineTrimNotice.consume())
        XCTAssertFalse(QuarantineTrimNotice.consume())
    }
}
