import XCTest
@testable import SendmeterCore

final class TagCurveCachePolicyTests: XCTestCase {
    private let accountA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let accountB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    func testOldFitIsRejectedAfterRecordingGenerationChanges() {
        let request = TagCurveCacheRequest(
            accountFetch: AccountScopedFetch(accountUserID: accountA, accountEpoch: 4),
            generation: 7
        )

        XCTAssertTrue(request.canApply(to: accountA, accountEpoch: 4, currentGeneration: 7))
        XCTAssertFalse(request.canApply(to: accountA, accountEpoch: 4, currentGeneration: 8))
        XCTAssertFalse(request.canApply(to: accountB, accountEpoch: 4, currentGeneration: 7))
        XCTAssertFalse(request.canApply(to: accountA, accountEpoch: 5, currentGeneration: 7))
    }
}
