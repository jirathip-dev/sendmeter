import XCTest
@testable import SendmeterCore

final class TrainingLoadInteractionTests: XCTestCase {
    func testActivityMixKeepsPaintedStripCompactButHitRegionComfortable() {
        XCTAssertEqual(TrainingLoadInteraction.activityMixVisualHeight, 10)
        XCTAssertGreaterThanOrEqual(TrainingLoadInteraction.activityMixHitHeight, 44)
        XCTAssertGreaterThan(TrainingLoadInteraction.activityMixHitHeight, TrainingLoadInteraction.activityMixVisualHeight)
    }

    func testWeeklyBarIndexUsesFlexibleSlotsAndClampsEdges() {
        // Width 320, four bars and 8pt gaps gives an 82pt slot: the same
        // partition as four flexible bars plus three 8pt HStack gaps.
        XCTAssertEqual(
            TrainingLoadInteraction.weeklyBarIndex(x: -1, width: 320, count: 4, spacing: 8),
            0
        )
        XCTAssertEqual(
            TrainingLoadInteraction.weeklyBarIndex(x: 81.99, width: 320, count: 4, spacing: 8),
            0
        )
        XCTAssertEqual(
            TrainingLoadInteraction.weeklyBarIndex(x: 82, width: 320, count: 4, spacing: 8),
            1
        )
        XCTAssertEqual(
            TrainingLoadInteraction.weeklyBarIndex(x: 246, width: 320, count: 4, spacing: 8),
            3
        )
        XCTAssertEqual(
            TrainingLoadInteraction.weeklyBarIndex(x: 999, width: 320, count: 4, spacing: 8),
            3
        )
    }

    func testWeeklyBarIndexRejectsEmptyOrInvalidGeometry() {
        XCTAssertNil(TrainingLoadInteraction.weeklyBarIndex(x: 10, width: 0, count: 4))
        XCTAssertNil(TrainingLoadInteraction.weeklyBarIndex(x: 10, width: 100, count: 0))
        XCTAssertNil(TrainingLoadInteraction.weeklyBarIndex(x: .infinity, width: 100, count: 4))
    }

    func testActivityMixIndexFollowsProportionalSharesAndOwnsRightEdge() {
        let shares = [60.0, 30.0, 10.0]
        XCTAssertEqual(TrainingLoadInteraction.activityMixIndex(x: -1, width: 200, percentages: shares), 0)
        XCTAssertEqual(TrainingLoadInteraction.activityMixIndex(x: 119.99, width: 200, percentages: shares), 0)
        XCTAssertEqual(TrainingLoadInteraction.activityMixIndex(x: 120, width: 200, percentages: shares), 1)
        XCTAssertEqual(TrainingLoadInteraction.activityMixIndex(x: 180, width: 200, percentages: shares), 2)
        XCTAssertEqual(TrainingLoadInteraction.activityMixIndex(x: 999, width: 200, percentages: shares), 2)
    }

    func testActivityMixIndexSkipsZeroWidthIntermediateSegments() {
        XCTAssertEqual(
            TrainingLoadInteraction.activityMixIndex(x: 0, width: 100, percentages: [0, 100]),
            1
        )
        XCTAssertNil(TrainingLoadInteraction.activityMixIndex(x: 0, width: 100, percentages: []))
    }

    func testToggledSelectionSelectsChangesAndDismissesSameValue() {
        XCTAssertEqual(
            TrainingLoadInteraction.toggledSelection(current: nil as Int?, candidate: 2),
            2
        )
        XCTAssertNil(TrainingLoadInteraction.toggledSelection(current: 2, candidate: 2))
        XCTAssertEqual(TrainingLoadInteraction.toggledSelection(current: 2, candidate: 3), 3)
    }
}
