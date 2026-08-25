import XCTest
@testable import SendmeterCore

final class PurgeGenerationFailurePolicyTests: XCTestCase {
    func testOnlyForegroundReportsAndRepeatedFailuresAreDeduplicated() {
        let account = UUID()
        var policy = PurgeGenerationFailurePolicy()

        XCTAssertFalse(policy.shouldSurface(
            context: .background,
            accountUserID: account,
            accountEpoch: 4
        ))
        XCTAssertFalse(policy.shouldSurface(
            context: .realtime,
            accountUserID: account,
            accountEpoch: 4
        ))
        XCTAssertTrue(policy.shouldSurface(
            context: .userInitiatedForeground,
            accountUserID: account,
            accountEpoch: 4
        ))
        XCTAssertFalse(policy.shouldSurface(
            context: .userInitiatedForeground,
            accountUserID: account,
            accountEpoch: 4
        ), "one outage must not replace the banner on every retry")
    }

    func testSuccessfulReadAndAccountEpochEndTheDeduplicationScope() {
        let account = UUID()
        var policy = PurgeGenerationFailurePolicy()

        XCTAssertTrue(policy.shouldSurface(
            context: .userInitiatedForeground,
            accountUserID: account,
            accountEpoch: 4
        ))
        policy.markAvailable(accountUserID: account, accountEpoch: 4)
        XCTAssertTrue(policy.shouldSurface(
            context: .userInitiatedForeground,
            accountUserID: account,
            accountEpoch: 4
        ))
        XCTAssertTrue(policy.shouldSurface(
            context: .userInitiatedForeground,
            accountUserID: account,
            accountEpoch: 5
        ))
    }
}
