import XCTest
@testable import SendLogWatchCore

/// #590 review F1: the truth table is tiny, but it is the single source of
/// the decision that keeps the unified finish/disconnect control from
/// discarding a rep that is actively recording — the view passes through
/// (see `ForceGaugeView`'s confirmation wiring), and
/// `TindeqHandsFreeIntegrationTests` drives the real manager through the
/// mid-confirm-pull interleaving against this same policy.
final class ForceFinishPolicyTests: XCTestCase {
    func testConfirmationDismissesExactlyWhenRecordingStarts() {
        XCTAssertTrue(ForceFinishPolicy.shouldDismissConfirmation(isMeasuring: true))
        XCTAssertFalse(ForceFinishPolicy.shouldDismissConfirmation(isMeasuring: false))
    }

    func testFinishNeverExecutesWhileARepIsRecording() {
        XCTAssertFalse(ForceFinishPolicy.mayExecuteFinish(isMeasuring: true))
        XCTAssertTrue(ForceFinishPolicy.mayExecuteFinish(isMeasuring: false))
    }
}
