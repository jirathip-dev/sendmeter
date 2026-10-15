@testable import SendmeterCore
import SendLogWatchCore
import XCTest

/// #1038 G5 + Safety + amendment H, second suite: the one-tap picker's
/// rules, the honest Guided-armed bar, and the "no wobble opens anything"
/// guarantee run through the REAL hands-free machine.
@MainActor
final class Force1038PickerAndSafetyTests: XCTestCase {

    // MARK: G5 — one tap applies and closes

    /// A movement whose last side is known commits in ONE tap, with that side.
    func testMovementWithAKnownLastSideCommitsInOneTap() {
        let outcome = MovementSidePickerPolicy.tapMovement(
            "Half crimp",
            mode: .unilateralOrBilateral,
            lastSide: .right
        )
        XCTAssertEqual(outcome, .commit(MovementSideDraft(movement: "Half crimp", side: .right)))
    }

    /// No side history: the sheet stays for the side — then the side tap
    /// closes it (two taps, never a Done button).
    func testMovementWithoutHistoryWaitsForTheSideThenCloses() {
        let first = MovementSidePickerPolicy.tapMovement("Pinch", mode: .unilateralOnly, lastSide: nil)
        guard case .needsSide(let draft) = first else {
            return XCTFail("a one-side movement with no history must ask for the side: \(first)")
        }
        XCTAssertEqual(draft.side, .unspecified)
        XCTAssertEqual(
            MovementSidePickerPolicy.tapSide(.left, draft: draft, mode: .unilateralOnly),
            .commit(MovementSideDraft(movement: "Pinch", side: .left))
        )
    }

    /// Bilateral-only and not-applicable movements have nothing to ask:
    /// one tap commits with the policy's side.
    func testMovementsWithNoSideChoiceCommitImmediately() {
        XCTAssertEqual(
            MovementSidePickerPolicy.tapMovement("Edge block", mode: .bilateralOnly, lastSide: .left),
            .commit(MovementSideDraft(movement: "Edge block", side: .both))
        )
        XCTAssertEqual(
            MovementSidePickerPolicy.tapMovement("Core", mode: .notApplicable, lastSide: .right),
            .commit(MovementSideDraft(movement: "Core", side: .unspecified))
        )
    }

    /// A remembered side the movement no longer allows is never reused.
    func testAStaleLastSideIsNotReused() {
        XCTAssertEqual(
            MovementSidePickerPolicy.defaultSide(for: "FDP", mode: .unilateralOnly, lastSide: .both),
            .unspecified
        )
        XCTAssertEqual(
            MovementSidePickerPolicy.defaultSide(for: "FDP", mode: .unilateralOrBilateral, lastSide: .both),
            .both
        )
    }

    /// A side the movement forbids is refused — the sheet stays open.
    func testAForbiddenSideTapDoesNotCommit() {
        let draft = MovementSideDraft(movement: "Pinch", side: .unspecified)
        XCTAssertEqual(
            MovementSidePickerPolicy.tapSide(.both, draft: draft, mode: .unilateralOnly),
            .needsSide(draft)
        )
    }

    /// Side first, movement second: a side tapped before any movement waits
    /// for the movement instead of closing on half a choice.
    func testASideWithoutAMovementKeepsTheSheetOpen() {
        let draft = MovementSideDraft(movement: "", side: .unspecified)
        XCTAssertEqual(
            MovementSidePickerPolicy.tapSide(.left, draft: draft, mode: .unilateralOrBilateral),
            .needsSide(MovementSideDraft(movement: "", side: .left))
        )
    }

    /// …and the movement tapped next commits WITH that side — the explicit
    /// choice beats the movement's history — unless the movement forbids it.
    func testASideTappedFirstWinsOverHistory() {
        XCTAssertEqual(
            MovementSidePickerPolicy.tapMovement(
                "Half crimp", mode: .unilateralOrBilateral, lastSide: .right, pendingSide: .left
            ),
            .commit(MovementSideDraft(movement: "Half crimp", side: .left))
        )
        XCTAssertEqual(
            MovementSidePickerPolicy.tapMovement(
                "Pinch", mode: .unilateralOnly, lastSide: .right, pendingSide: .both
            ),
            .commit(MovementSideDraft(movement: "Pinch", side: .right)),
            "a forbidden pending side falls back to the movement's history"
        )
        XCTAssertEqual(
            MovementSidePickerPolicy.tapMovement(
                "Edge block", mode: .bilateralOnly, lastSide: nil, pendingSide: .left
            ),
            .commit(MovementSideDraft(movement: "Edge block", side: .both))
        )
    }

    /// The side default is the NEWEST pull's side for that movement.
    func testLastSidesComeFromTheNewestPull() {
        let sides = MovementSidePickerPolicy.lastSides(from: [
            pull("FDP", .left, day: 1),
            pull("FDP", .right, day: 3),
            pull("Half crimp", .both, day: 2),
            pull("Pinch", .unspecified, day: 4)
        ])
        XCTAssertEqual(sides["FDP"], .right)
        XCTAssertEqual(sides["Half crimp"], .both)
        XCTAssertNil(sides["Pinch"], "an unspecified side is no default")
    }

    /// Picker proposal: recently used first (newest first), the rest in
    /// catalog order, nothing lost or duplicated.
    func testRecentMovementsComeFirst() {
        let catalog = ["Edge block", "FDP", "Half crimp", "Pinch", "Lock-off"]
        let split = MovementSidePickerPolicy.recentFirst(catalog, recordings: [
            pull("FDP", .left, day: 5),
            pull("Pinch", .left, day: 9),
            pull("Half crimp", .right, day: 1)
        ], limit: 2)
        XCTAssertEqual(split.recent, ["Pinch", "FDP"])
        XCTAssertEqual(split.other, ["Edge block", "Half crimp", "Lock-off"])
        XCTAssertEqual(Set(split.recent + split.other), Set(catalog))
    }

    // MARK: H2 — the side column carries information or is gone

    /// The picker only badges a movement whose side policy DIFFERS from the
    /// default "either" — nine identical "Either" cells are gone.
    func testOnlyNonDefaultSidePoliciesAreBadged() {
        XCTAssertNil(MovementSideBadge.badge(for: .unilateralOrBilateral))
        XCTAssertEqual(MovementSideBadge.badge(for: .unilateralOnly), "One side")
        XCTAssertEqual(MovementSideBadge.badge(for: .bilateralOnly), "Both only")
        XCTAssertEqual(MovementSideBadge.badge(for: .notApplicable), "No side")
    }

    // MARK: G3 — Guided with a protocol picked reads as armed

    func testGuidedWithAProtocolReadsArmedWithStart() {
        let state = ForceBarPolicy.state(
            ForceBarInput(
                device: .connected,
                mode: .guided,
                armedProtocolName: "Strength",
                handsFreeArmed: false,
                handsFreeMeasuring: false,
                hasHeldPull: false,
                guidedSessionActive: false,
                hasRecordings: true
            )
        )
        XCTAssertEqual(state.status, "Armed · tap Start")
        XCTAssertEqual(state.tone, .armed)
        XCTAssertEqual(state.action, .startGuided)
        XCTAssertTrue(state.actionIsPrimary)
    }

    // MARK: Safety — a sub-threshold wobble opens nothing

    /// Feeds the REAL hands-free machine (shipping config) a wobble that
    /// crosses the start threshold but never dwells there, then a hang below
    /// it. The presentation decision is taken from the machine after every
    /// sample — exactly what ForceView's `.onChange(of: isMeasuring)` reads —
    /// and must never ask for the full screen. A real pull then does.
    func testASubThresholdWobbleNeverPresentsTheFullScreen() {
        let config = HandsFreeForceConfig.default
        let controller = HandsFreeForceController(config: config)
        controller.arm()
        XCTAssertTrue(controller.isArmed)

        var presented = false
        func step(_ ms: Double, _ kg: Double) {
            controller.feed(atMs: ms, kg: kg)
            if FreeHoldPresentation.request(
                measuring: controller.isMeasuring,
                alreadyPresented: presented,
                guidedSessionActive: false
            ) == .present {
                presented = true
            }
        }

        // 1) Spikes ABOVE startKg, each shorter than startStableMs.
        var t = 0.0
        let spike = config.startStableMs * 0.4
        for _ in 0..<12 {
            step(t, config.startKg + 1.5); t += spike / 2
            step(t, config.startKg + 1.5); t += spike / 2
            step(t, config.stopKg * 0.5); t += 200
        }
        // 2) A long, steady load just BELOW the start threshold.
        for _ in 0..<60 {
            step(t, config.startKg * 0.9); t += 100
        }
        XCTAssertFalse(controller.isMeasuring, "the wobble must not start a recording")
        XCTAssertFalse(presented, "a sub-threshold wobble must open no full screen")
        XCTAssertTrue(controller.isArmed, "and the loop stays armed for the real pull")

        // 3) A real pull: above the threshold for longer than the dwell.
        let pullEnd = t + config.startStableMs * 2
        while t <= pullEnd {
            step(t, config.startKg + 10); t += 50
        }
        XCTAssertTrue(controller.isMeasuring)
        XCTAssertTrue(presented, "the first real pull opens the full screen")
    }

    // MARK: Free hold full screen — the chart fills, never a dead gap

    func testTheFreeHoldChartTakesTheRemainingHeightWithinBounds() {
        // 17 Pro cover (778) with the 68-pt controls and 330 pt of sections:
        // the chart takes the remaining 380 as-is (a phone always fills).
        XCTAssertEqual(FreeHoldLayout.chartHeight(viewport: 778, controls: 68, nonChart: 330), 380)
        // Between pulls the stop control is gone: the chart takes its 68 pt.
        XCTAssertEqual(FreeHoldLayout.chartHeight(viewport: 778, controls: 0, nonChart: 330), 448)
        // An iPad-size cover is bounded at the 480 maximum.
        XCTAssertEqual(FreeHoldLayout.chartHeight(viewport: 1300, controls: 0, nonChart: 330), 480)
        // SE cover (647): 647 − 68 − 330 = 249, used as-is.
        XCTAssertEqual(FreeHoldLayout.chartHeight(viewport: 647, controls: 68, nonChart: 330), 249)
        // Accessibility sizes push the sections down: never below 150 —
        // the stack scrolls instead.
        XCTAssertEqual(FreeHoldLayout.chartHeight(viewport: 647, controls: 68, nonChart: 520), 150)
        // First pass, nothing measured yet.
        XCTAssertEqual(FreeHoldLayout.chartHeight(viewport: 778, controls: 68, nonChart: nil), 150)
    }

    // MARK: Helpers

    private func pull(_ tag: String, _ side: TindeqSide, day: Int) -> TindeqRecording {
        TindeqRecording(
            id: UUID(),
            recordedAt: Date(timeIntervalSince1970: Double(day) * 86_400),
            durationMilliseconds: 10_000,
            peakKilograms: 30,
            averageKilograms: 28,
            sampleCount: 10,
            note: "",
            tag: tag,
            side: side,
            groupID: nil
        )
    }
}
