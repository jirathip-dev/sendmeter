import XCTest
@testable import SendmeterCore

/// Pins the haptics decision layer (#656) to the web's `tapHaptics.ts` /
/// `haptics.ts` semantics — the decision logic is pure Core so a regression
/// is caught by `swift test` instead of a device.
final class HapticsTests: XCTestCase {
    // MARK: Guided transition patterns (web ForceFullscreen.tsx table)

    func testHoldTransitionCuesSingle150() {
        XCTAssertEqual(
            GuidedTransitionHaptics.cue(entering: .work),
            .pattern(.single(milliseconds: 150))
        )
    }

    func testSwitchCuesStutter() {
        XCTAssertEqual(
            GuidedTransitionHaptics.cue(entering: .switchSide),
            .pattern(.stutter(milliseconds: [80, 60, 80]))
        )
    }

    func testRestAndPrepareCueLikeSwitch() {
        // The web cues everything that isn't a hold/move as `[80,60,80]`
        // (phase !== hold/move → the else branch).
        XCTAssertEqual(
            GuidedTransitionHaptics.cue(entering: .prepare),
            .pattern(.stutter(milliseconds: [80, 60, 80]))
        )
        XCTAssertEqual(
            GuidedTransitionHaptics.cue(entering: .restBetweenRepetitions),
            .pattern(.stutter(milliseconds: [80, 60, 80]))
        )
        XCTAssertEqual(
            GuidedTransitionHaptics.cue(entering: .restBetweenSets),
            .pattern(.stutter(milliseconds: [80, 60, 80]))
        )
    }

    func testCompleteCuesStutter() {
        // Review F3: the `.complete` case was dead code — the run's
        // `isComplete` guard made every later tick return before the
        // transition block. It is now fired on advance, so it must be pinned
        // like every other stage.
        XCTAssertEqual(
            GuidedTransitionHaptics.cue(entering: .complete),
            .pattern(.stutter(milliseconds: [80, 60, 80]))
        )
    }

    // MARK: Single-buzz weight mapping (review F11)

    func testSingleBuzzWeightMapsByDuration() {
        // The web distinguishes single buzzes by duration (hold 150, armed
        // 80, in-zone 45); UIImpactFeedbackGenerator has no duration axis, so
        // the pure mapping encodes duration → intensity.
        XCTAssertEqual(HapticPatternWeights.singleWeight(milliseconds: 150), .heavy)
        XCTAssertEqual(HapticPatternWeights.singleWeight(milliseconds: 80), .light)
        XCTAssertEqual(HapticPatternWeights.singleWeight(milliseconds: 45), .light)
        XCTAssertEqual(HapticPatternWeights.singleWeight(milliseconds: 100), .medium)
    }

    // MARK: Hands-free armed/measuring (web `armed ? 80 : 150`)

    func testHandsFreeArmedCuesSingle80() {
        XCTAssertEqual(
            HandsFreeHaptics.cue(for: .armed),
            .pattern(.single(milliseconds: 80))
        )
    }

    func testHandsFreeMeasuringCuesSingle150() {
        XCTAssertEqual(
            HandsFreeHaptics.cue(for: .measuring),
            .pattern(.single(milliseconds: 150))
        )
    }

    // MARK: Selection guard — once per VALUE change, zero in-band

    func testScrubTickFiresOncePerValueChange() {
        let a = 1
        let b = 2
        XCTAssertTrue(SelectionHaptics.valueChanged(nil as Int?, a))
        XCTAssertTrue(SelectionHaptics.valueChanged(a, b))
        XCTAssertFalse(SelectionHaptics.valueChanged(b, b))
    }

    func testScrubStayingInBandStaysSilent() {
        let day = "2026-08-01"
        // A second observation of the same value — the finger never left the
        // band — must not fire.
        XCTAssertFalse(SelectionHaptics.valueChanged(day, day))
    }

    func testTrainingLoadScrubTicksOnSelectionAndDismissal() {
        let day = "2026-08-02"

        // Weekly bars, activity segments and the heatmap all call this guard
        // from their gesture handlers. Dismissal is a deliberate value change
        // and therefore gets the same crisp selection cue; rebuilding data is
        // handled separately and never calls the guard.
        XCTAssertTrue(SelectionHaptics.valueChanged(nil as String?, day))
        XCTAssertFalse(SelectionHaptics.valueChanged(day, day))
        XCTAssertTrue(SelectionHaptics.valueChanged(day, nil))
        XCTAssertTrue(SelectionHaptics.valueChanged(nil, day))
    }

    // MARK: Vocabulary pins (#656 spec table)

    func testSelectionCueIsDistinctFromLight() {
        // The issue's table says scrub/point selection is `.selection`, a
        // DIFFERENT generator from the sheet-open `.light` (review F4).
        XCTAssertNotEqual(HapticCue.selection, HapticCue.light)
    }

    // MARK: Refused vs disabled (#222)

    func testRefusedTappableFiresWarning() {
        XCTAssertEqual(
            RefusedActionHaptics.cue(tappableAndRefused: true),
            .warning
        )
    }

    func testGenuinelyDisabledFiresNothing() {
        // A truly disabled control has nothing behind the tap: no cue at all.
        XCTAssertNil(RefusedActionHaptics.cue(tappableAndRefused: false))
    }

    // MARK: Sheet gate — one tick per gesture, freshness window

    func testSheetGateSpendsExactlyOneTickPerGesture() {
        var gate = HapticGestureGate()
        let now: Double = 1_000_000
        gate.tap(nowMs: now)
        XCTAssertTrue(gate.claim(nowMs: now + 10))
        // The same gesture's tick is spent.
        XCTAssertFalse(gate.claim(nowMs: now + 20))
    }

    func testSheetGateSilentWithoutTap() {
        var gate = HapticGestureGate()
        // No tap armed the gate — a sheet appearing on its own stays silent.
        XCTAssertFalse(gate.claim(nowMs: 5_000))
    }

    func testSheetGateSilentOutsideFreshnessWindow() {
        var gate = HapticGestureGate()
        let now: Double = 1_000_000
        gate.tap(nowMs: now)
        // Beyond GESTURE_FRESH_MS (1.5 s) the gesture is stale.
        XCTAssertFalse(gate.claim(nowMs: now + 2_000))
    }

    func testSheetGateRearmsOnNewGesture() {
        var gate = HapticGestureGate()
        let now: Double = 1_000_000
        gate.tap(nowMs: now)
        XCTAssertTrue(gate.claim(nowMs: now + 10))
        // A fresh tap re-arms the gate.
        gate.tap(nowMs: now + 2_000)
        XCTAssertTrue(gate.claim(nowMs: now + 2_010))
    }
}
