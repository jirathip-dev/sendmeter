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

    func testOptimisticRecordingIsEligibleOnlyWhenItsSamplesAreAvailable() {
        let persistedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let pendingID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let pendingIDs: Set<UUID> = [pendingID]

        XCTAssertTrue(
            TagCurveCachePolicy.includes(
                recordingID: persistedID,
                pendingIDs: pendingIDs,
                locallyAvailableSampleIDs: []
            )
        )
        XCTAssertFalse(
            TagCurveCachePolicy.includes(
                recordingID: pendingID,
                pendingIDs: pendingIDs,
                locallyAvailableSampleIDs: []
            )
        )
        XCTAssertTrue(
            TagCurveCachePolicy.includes(
                recordingID: pendingID,
                pendingIDs: pendingIDs,
                locallyAvailableSampleIDs: [pendingID]
            )
        )
    }

    func testEqualUploadStillInvalidatesTheJustSavedKey() {
        let key = TagCurveCacheKey(tag: " Crimp ", modality: "static")

        XCTAssertEqual(
            TagCurveCachePolicy.affectedKeys(old: key, new: key),
            Set([key])
        )
    }

    func testDifferentUploadInvalidatesBothOldAndNewKeys() {
        let old = TagCurveCacheKey(tag: "crimp", modality: "static")
        let new = TagCurveCacheKey(tag: "pinch", modality: "reverse_action")

        XCTAssertEqual(
            TagCurveCachePolicy.affectedKeys(old: old, new: new),
            Set([old, new])
        )
    }

    func testOneRecordingMutationDoesNotInvalidateEveryTag() {
        let changed = TagCurveCacheKey(tag: "crimp", modality: "static")
        let unrelated = TagCurveCacheKey(tag: "pinch", modality: "static")
        var generations = TagCurveCacheGenerationIndex()

        generations.invalidate([changed])

        XCTAssertEqual(generations.generation(for: changed), 1)
        XCTAssertEqual(generations.generation(for: unrelated), 0)
    }

    func testRPEPathIsPointEstimateOnlyWhileChartPathOwnsTheBand() {
        XCTAssertEqual(TagCurveFitPurpose.pointEstimate.bootstrapSamples, 0)
        XCTAssertEqual(TagCurveFitPurpose.chartBand.bootstrapSamples, 200)
    }

    func testKeyNormalizationMakesWhitespaceAndCaseEditsOneFit() {
        XCTAssertEqual(
            TagCurveCacheKey(tag: "  CRIMP  ", modality: "static"),
            TagCurveCacheKey(tag: "crimp", modality: "static")
        )
    }
}
