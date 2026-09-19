import XCTest
@testable import SendmeterCore

/// #923: one refresh pass is nine independent slices inside seven consistency
/// groups. These pin what may publish after a partial failure, which pairs are
/// all-or-nothing, and when the global failure surface may still escalate.
final class RefreshSlicePlanTests: XCTestCase {

    // MARK: - Grouping

    func testEverySliceBelongsToExactlyOneGroup() {
        for slice in RefreshSlice.allCases {
            let groups = RefreshConsistencyGroup.allCases.filter { $0.slices.contains(slice) }
            XCTAssertEqual(groups.count, 1, "\(slice) must have exactly one group")
            XCTAssertEqual(RefreshConsistencyGroup.group(of: slice), groups[0])
        }
        let members = RefreshConsistencyGroup.allCases.flatMap(\.slices)
        XCTAssertEqual(Set(members).count, RefreshSlice.allCases.count)
    }

    func testDependentPairsAreGroupsWithTwoSlices() {
        XCTAssertEqual(
            Set(RefreshConsistencyGroup.sessionsAndRecordings.slices),
            [RefreshSlice.sessions, .recordings]
        )
        XCTAssertEqual(
            Set(RefreshConsistencyGroup.settingsAndPhase.slices),
            [RefreshSlice.settings, .phasePeriods]
        )
        XCTAssertEqual(
            RefreshConsistencyGroup.workoutsAndAttempts.slices,
            [.workoutsAndAttempts],
            "attempts are children of the workout page: one slice, one group"
        )
    }

    // MARK: - AC1: independent slices still publish after a sibling failure

    func testOneUnrelatedFailureStillPublishesTheIndependentGroups() {
        var outcomes = RefreshSliceOutcomes()
        outcomes.record(slice: .sessions, failed: false)
        outcomes.record(slice: .recordings, failed: false)
        outcomes.record(slice: .healthMetrics, failed: true)

        XCTAssertTrue(outcomes.publishes(.sessionsAndRecordings))
        XCTAssertFalse(outcomes.publishes(.healthMetrics))
        XCTAssertTrue(outcomes.didPublishAnyGroup)
        XCTAssertFalse(outcomes.didFullyRefresh)
        XCTAssertEqual(outcomes.failedGroups, [.healthMetrics])
        XCTAssertEqual(outcomes.failedSlicesInOrder, [.healthMetrics])
    }

    func testAllSlicesSucceedingIsTheOnlyFullRefresh() {
        var outcomes = RefreshSliceOutcomes()
        for slice in RefreshSlice.allCases {
            outcomes.record(slice: slice, failed: false)
        }
        XCTAssertTrue(outcomes.didFullyRefresh)
        XCTAssertEqual(outcomes.publishableGroups.count, RefreshConsistencyGroup.allCases.count)
        XCTAssertTrue(outcomes.failedGroups.isEmpty)
    }

    func testEverySliceFailingPublishesNothing() {
        var outcomes = RefreshSliceOutcomes()
        for slice in RefreshSlice.allCases {
            outcomes.record(slice: slice, failed: true)
        }
        XCTAssertFalse(outcomes.didPublishAnyGroup)
        XCTAssertFalse(outcomes.didFullyRefresh)
        XCTAssertEqual(outcomes.failedGroups.count, RefreshConsistencyGroup.allCases.count)
    }

    // MARK: - AC2: a dependent pair never publishes half

    func testASettingsFailureBlocksItsPairedSliceAndNothingElse() {
        var outcomes = RefreshSliceOutcomes()
        for slice in RefreshSlice.allCases where slice != .settings {
            outcomes.record(slice: slice, failed: false)
        }
        outcomes.record(slice: .settings, failed: true)

        XCTAssertFalse(
            outcomes.publishes(.settingsAndPhase),
            "a settings row the phase rows do not agree with is never exposed"
        )
        // The settings failure must not touch the pair's siblings.
        XCTAssertTrue(outcomes.publishes(.sessionsAndRecordings))
        XCTAssertTrue(outcomes.publishes(.presets))
        XCTAssertEqual(outcomes.failedGroups, [.settingsAndPhase])
    }

    func testAPeriodFailureBlocksTheWholePair() {
        var outcomes = RefreshSliceOutcomes()
        outcomes.record(slice: .settings, failed: false)
        outcomes.record(slice: .phasePeriods, failed: true)
        XCTAssertFalse(outcomes.publishes(.settingsAndPhase))
        XCTAssertEqual(outcomes.publishableGroups.count, RefreshConsistencyGroup.allCases.count - 1)
    }

    // MARK: - AC4: cancellation is not a verdict

    func testCancellationPublishesNothingAndReportsNothing() {
        var outcomes = RefreshSliceOutcomes()
        outcomes.record(slice: .sessions, failed: false)
        outcomes.markCancelled()

        XCTAssertFalse(
            outcomes.publishes(.sessionsAndRecordings),
            "a cancelled pass applies neither the slices that returned nor the ones that did not"
        )
        XCTAssertFalse(outcomes.didPublishAnyGroup)
        XCTAssertFalse(outcomes.didFullyRefresh)
        XCTAssertTrue(
            outcomes.failedGroups.isEmpty,
            "a cancelled pass is not a failure to report"
        )
    }

    // MARK: - The scoped failure row

    func testScopedFailureNamesTheFailedGroupsAndTheReason() {
        let summary = RefreshFailureSummary(
            accountUserID: UUID(),
            groups: [.healthMetrics, .tagMetadata],
            reason: UserFacingError.message(for: FriendlyErrorClass.offline),
            source: .userInitiated,
            occurredAt: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(summary.groupNames, "Health metrics and Exercise tags")
        XCTAssertTrue(summary.message.contains("Health metrics and Exercise tags"))
        XCTAssertTrue(summary.message.contains("didn't refresh"))
        XCTAssertTrue(
            summary.message.contains("The rest of your data is up to date"),
            "a partial failure is scoped, never a total blackout"
        )
    }

    func testOneFailedGroupReadsNaturally() {
        let summary = RefreshFailureSummary(
            accountUserID: UUID(),
            groups: [.settingsAndPhase],
            reason: "Couldn't reach Sendmeter.",
            source: .background,
            occurredAt: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(summary.groupNames, "Settings and training blocks")
        XCTAssertEqual(
            summary.message,
            "Settings and training blocks didn't refresh (Couldn't reach Sendmeter.). The rest of your data is up to date."
        )
    }

    // MARK: - The #842/#923 escalation matrix

    func testPartialPublicationSuppressesTheGlobalBanner() {
        let policy = ErrorSurfacePolicy()
        XCTAssertFalse(
            policy.shouldSurface(
                source: .userInitiated,
                hasLastGoodData: false,
                publishedAnySlice: true
            ),
            "the total-offline copy is false while a published slice is on screen"
        )
        XCTAssertFalse(
            policy.shouldSurface(
                source: .background,
                hasLastGoodData: true,
                publishedAnySlice: true
            )
        )
    }

    func testNothingPublishedKeepsTheDocumentedMatrix() {
        let policy = ErrorSurfacePolicy()
        XCTAssertTrue(
            policy.shouldSurface(
                source: .userInitiated,
                hasLastGoodData: false,
                publishedAnySlice: false
            )
        )
        XCTAssertTrue(
            policy.shouldSurface(
                source: .background,
                hasLastGoodData: false,
                publishedAnySlice: false
            )
        )
        XCTAssertFalse(
            policy.shouldSurface(
                source: .background,
                hasLastGoodData: true,
                publishedAnySlice: false
            )
        )
    }
}
