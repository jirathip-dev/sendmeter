@testable import SendmeterCore
import XCTest

/// #1038: the Free hold mode's policies — the full screen's phases, the
/// self-arming rule (G3), the session strip and its Finish gate (amendment I),
/// the one-tap picker's fixes (G4/H1/H2) and the last-pull summary (G6).
final class Force1038PolicyTests: XCTestCase {

    // MARK: I1/I2/I3 — the sticky bar's gauge session

    private func bar(
        _ device: ForceBarDevice = .connected,
        _ mode: ForceBarMode = .handsFree,
        handsFreeArmed: Bool = true,
        handsFreeMeasuring: Bool = false,
        held: Bool = false,
        session: Bool = false,
        saving: Bool = false,
        gaugeSessionCount: Int = 0,
        freeHoldContext: String? = nil
    ) -> ForceBarState {
        ForceBarPolicy.state(
            ForceBarInput(
                device: device,
                mode: mode,
                armedProtocolName: "Max Hangs 10 s",
                handsFreeArmed: handsFreeArmed,
                handsFreeMeasuring: handsFreeMeasuring,
                hasHeldPull: held,
                guidedSessionActive: session,
                saving: saving,
                hasRecordings: true,
                gaugeSessionCount: gaugeSessionCount,
                freeHoldContext: freeHoldContext
            )
        )
    }

    /// I1: the strip appears exactly when the session holds recordings, and
    /// the count is what it holds.
    func testSessionStripAppearsWithRecordings() {
        XCTAssertNil(bar(gaugeSessionCount: 0).session)
        let one = bar(gaugeSessionCount: 1).session
        XCTAssertEqual(one?.count, 1)
        XCTAssertEqual(one?.countLabel, "1 recording")
        XCTAssertEqual(bar(gaugeSessionCount: 3).session?.countLabel, "3 recordings")
        XCTAssertTrue(one?.canFinish == true)
    }

    /// I3: Finish is unavailable mid-recording, mid-guided-run, and over an
    /// unsaved held pull — each with the reason the disabled control reads.
    func testFinishIsBlockedInEveryUnsafeMoment() {
        XCTAssertEqual(
            bar(handsFreeMeasuring: true, gaugeSessionCount: 2).session?.finishBlockedReason,
            "Finish after this pull is saved"
        )
        XCTAssertEqual(
            bar(.measuring, gaugeSessionCount: 2).session?.finishBlockedReason,
            "Finish after this pull is saved"
        )
        XCTAssertEqual(
            bar(session: true, gaugeSessionCount: 2).session?.finishBlockedReason,
            "Finish after the guided protocol ends"
        )
        XCTAssertEqual(
            bar(held: true, gaugeSessionCount: 2).session?.finishBlockedReason,
            "Save or discard the held pull first"
        )
        XCTAssertEqual(
            bar(saving: true, gaugeSessionCount: 2).session?.finishBlockedReason,
            "Finishing…"
        )
        for blocked in [
            bar(handsFreeMeasuring: true, gaugeSessionCount: 2),
            bar(session: true, gaugeSessionCount: 2),
            bar(held: true, gaugeSessionCount: 2),
            bar(saving: true, gaugeSessionCount: 2)
        ] {
            XCTAssertFalse(
                blocked.session?.canFinish ?? true,
                "a blocked Finish must be disabled, not merely labelled"
            )
        }
    }

    /// I1: the count stays visible while Finish is blocked — the user can
    /// always see what the session holds.
    func testCountStaysVisibleWhileFinishIsBlocked() {
        let held = bar(held: true, gaugeSessionCount: 4)
        XCTAssertEqual(held.session?.count, 4)
        XCTAssertFalse(held.session?.canFinish ?? true)
        XCTAssertNotNil(held.session?.finishBlockedReason)
    }

    /// I2: a count of zero is no session to log.
    func testFinishNeedsASessionToLog() {
        XCTAssertFalse(ForceFinishPolicy.canFinish(count: 0, blockedReason: nil))
        XCTAssertFalse(ForceFinishPolicy.canFinish(count: 1, blockedReason: "Finishing…"))
        XCTAssertTrue(ForceFinishPolicy.canFinish(count: 1, blockedReason: nil))
    }

    /// I2: Finish ends the session and THEN disconnects. A failed end must
    /// keep the Progressor connected — the ordering is the safety property,
    /// and it is the same `ForceFinishSequence` the app runs.
    func testFinishDisconnectsOnlyAfterACompletedEnd() {
        XCTAssertTrue(ForceFinishSequence.disconnects(after: .logged))
        // Nothing was recorded into the session: the session is not at risk,
        // so the explicit disconnect still stands.
        XCTAssertTrue(ForceFinishSequence.disconnects(after: .nothingToEnd))
        // The end failed: the pull data is still on the Progressor.
        XCTAssertFalse(ForceFinishSequence.disconnects(after: .failed))
    }

    /// I2/I3: the view's Finish guard re-checks the same policy the bar
    /// renders from, so a stale tap can never end a session mid-pull. The
    /// wiring plus the rule are asserted together — a guard that drifted off
    /// the policy would pass either check alone.
    func testFinishGuardReChecksTheSessionPolicy() {
        let forceView = code(source("Sources/Features/Force/ForceView.swift"))
        let normalized = normalizeWhitespace(forceView)
        XCTAssertTrue(normalized.contains("guard let session = forceBarState.session, session.canFinish else { return }"))
        XCTAssertTrue(forceView.contains("await model.finishGaugeSessionAndDisconnect()"))

        let appModel = code(source("Sources/App/AppModel.swift"))
        XCTAssertTrue(appModel.contains("if ForceFinishSequence.disconnects(after: outcome)"))
        XCTAssertTrue(appModel.contains("await endGaugeSessionReportingOutcome()"))
    }

    // MARK: G1/G3 — the Free hold full screen

    /// G1: three phases, and no phase shows a live force number on the tab —
    /// the labels are the whole operating instruction.
    func testFreeHoldPhases() {
        XCTAssertEqual(FreeHoldPhase.waiting.label, "PULL TO START")
        XCTAssertEqual(FreeHoldPhase.recording.label, "HOLDING")
        XCTAssertEqual(FreeHoldPhase.saved.label, "SAVED")
        XCTAssertEqual(FreeHoldPhase.waiting.symbol, "hand.draw.fill")
        XCTAssertEqual(FreeHoldPhase.saved.symbol, "checkmark.circle.fill")
    }

    /// G3: the screen opens on the first PULL — never on arming, never on a
    /// sub-threshold wobble (the machine's own `isMeasuring` is the trigger).
    func testFullScreenOpensOnTheFirstPullOnly() {
        XCTAssertEqual(
            FreeHoldPresentation.request(measuring: true, alreadyPresented: false, guidedSessionActive: false),
            .present
        )
        XCTAssertEqual(
            FreeHoldPresentation.request(measuring: false, alreadyPresented: false, guidedSessionActive: false),
            .none
        )
        XCTAssertEqual(
            FreeHoldPresentation.request(measuring: true, alreadyPresented: true, guidedSessionActive: false),
            .none
        )
        XCTAssertEqual(
            FreeHoldPresentation.request(measuring: true, alreadyPresented: false, guidedSessionActive: true),
            .none,
            "a guided run owns the device"
        )
    }

    /// G3: arming is automatic — but never into an unsafe moment, and never
    /// against the user's own Disarm.
    func testAutoArmRules() {
        XCTAssertTrue(autoArm(connected: true))
        XCTAssertFalse(autoArm(connected: false))
        XCTAssertFalse(autoArm(mode: .guided))
        XCTAssertFalse(autoArm(armed: true))
        XCTAssertFalse(autoArm(measuring: true))
        XCTAssertFalse(autoArm(hasHeldPull: true))
        XCTAssertFalse(autoArm(guidedSessionActive: true))
        XCTAssertFalse(autoArm(saving: true))
        XCTAssertFalse(autoArm(userDisarmed: true), "an explicit Disarm is the user's decision")
    }

    private func autoArm(
        mode: ForceBarMode = .handsFree,
        connected: Bool = true,
        armed: Bool = false,
        measuring: Bool = false,
        hasHeldPull: Bool = false,
        guidedSessionActive: Bool = false,
        saving: Bool = false,
        userDisarmed: Bool = false
    ) -> Bool {
        FreeHoldAutoArmPolicy.shouldArm(
            FreeHoldAutoArmInput(
                mode: mode,
                connected: connected,
                armed: armed,
                measuring: measuring,
                hasHeldPull: hasHeldPull,
                guidedSessionActive: guidedSessionActive,
                saving: saving,
                userDisarmed: userDisarmed
            )
        )
    }

    // MARK: G2 — the mode's name

    /// G2: "Free hold" everywhere the mode is named; the raw value survives so
    /// the persisted switch and the a11y ids do not churn.
    func testModeNameIsFreeHold() {
        XCTAssertEqual(ForceBarMode.handsFree.title, "Free hold")
        XCTAssertEqual(ForceBarMode.handsFree.rawValue, "handsFree")
        XCTAssertEqual(ForceBarPolicy.freeHoldSubject, "Free hold")
        XCTAssertEqual(bar(.connected, .handsFree).subjectCaption, "Free hold")
        XCTAssertEqual(bar(.connected, .guided).subjectCaption, "Protocol")
    }

    /// G1/G2: the Free hold subject carries the movement the pull records
    /// under — never a second "Free hold" under a "Free hold" caption.
    func testFreeHoldSubjectCarriesTheMovement() {
        let named = bar(.connected, .handsFree, freeHoldContext: "FDP · Left")
        XCTAssertEqual(named.subject, "FDP · Left")
        XCTAssertNotEqual(named.subject, named.subjectCaption)
        // With no movement named yet, the mode word is the honest subject.
        let bare = bar(.connected, .handsFree)
        XCTAssertEqual(bare.subject, ForceBarPolicy.freeHoldSubject)
    }

    /// G2: Guided keeps the protocol name as its subject, and the two modes
    /// never share a caption.
    func testGuidedSubjectIsTheProtocol() {
        let guided = bar(.connected, .guided)
        XCTAssertEqual(guided.subject, "Max Hangs 10 s")
        XCTAssertEqual(guided.subjectCaption, "Protocol")
        XCTAssertTrue(guided.subjectOpensProtocolList)
        XCTAssertFalse(bar(.connected, .handsFree).subjectOpensProtocolList)
    }

    // MARK: G4 — one-tap protocol selection

    /// G4: picking a protocol selects Guided immediately — including from
    /// Free hold. Panning to "Free" is a Guided choice (it is the armed slot).
    func testPickingAProtocolSwitchesToGuided() {
        let id = UUID()
        XCTAssertEqual(ForceProtocolSelectionRouting.mode(afterSelecting: .free), nil)
        XCTAssertEqual(ForceProtocolSelectionRouting.mode(afterSelecting: .savedPreset(id)), .guided)
        XCTAssertEqual(ForceProtocolSelectionRouting.mode(afterSelecting: .suggestedZone(.strength)), .guided)
        XCTAssertEqual(ForceProtocolSelectionRouting.mode(afterSelecting: .suggestedMaintenance(.prehab)), .guided)
        XCTAssertEqual(ForceProtocolSelectionRouting.mode(afterSelecting: .movement), .guided)
    }

    // MARK: H1 — the intensity dial's ticks

    /// H1: 100 is at 80 % of the 60–110 track, not its centre.
    func testIntensityTickPositions() {
        XCTAssertEqual(IntensityScale.fraction(60), 0, accuracy: 0.0001)
        XCTAssertEqual(IntensityScale.fraction(100), 0.8, accuracy: 0.0001)
        XCTAssertEqual(IntensityScale.fraction(110), 1, accuracy: 0.0001)
        // Below/above the scale clamps rather than drawing off the track.
        XCTAssertEqual(IntensityScale.fraction(10), 0, accuracy: 0.0001)
        XCTAssertEqual(IntensityScale.fraction(900), 1, accuracy: 0.0001)
        // A 300 pt track: the thumb travels 14…286, and 100 lands at
        // 14 + 0.8 * 272 = 231.6 — not at the geometric centre (150).
        XCTAssertEqual(IntensityScale.center(value: 100, trackWidth: 300), 231.6, accuracy: 0.001)
        XCTAssertEqual(IntensityScale.center(value: 60, trackWidth: 300), 14, accuracy: 0.001)
        XCTAssertEqual(IntensityScale.center(value: 110, trackWidth: 300), 286, accuracy: 0.001)
        // A track narrower than the thumb never produces a negative inset.
        XCTAssertEqual(IntensityScale.center(value: 60, trackWidth: 10), 5, accuracy: 0.001)
    }

    // MARK: H2 — the movement rows' area hints

    /// H2: rows read as climbing movements, and an unknown movement gets no
    /// invented claim.
    func testMovementAreaHints() {
        XCTAssertEqual(MovementAreaHint.hint(for: "FDP"), "Fingers · deep flexor")
        XCTAssertEqual(MovementAreaHint.hint(for: "fdp"), "Fingers · deep flexor")
        XCTAssertEqual(MovementAreaHint.hint(for: "Half crimp"), "Fingers · half crimp grip")
        XCTAssertEqual(MovementAreaHint.hint(for: "Lock-off"), "Back and arms")
        XCTAssertNil(MovementAreaHint.hint(for: "Mystery hold"), "no invented anatomy")
        XCTAssertNil(MovementAreaHint.hint(for: "   "))
    }

    // MARK: G6 — the last-pull summary

    func testLastPullContextLine() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let line = ForceLastPullFormat.contextLine(
            tag: "FDP",
            side: .left,
            recordedAt: now.addingTimeInterval(-3_600),
            now: now,
            locale: Locale(identifier: "en_US")
        )
        XCTAssertTrue(line.hasPrefix("FDP · Left · "), line)
        XCTAssertTrue(line.contains("hour"), line)

        // Nothing to name: the age still carries the line, with no empty
        // separators.
        let bare = ForceLastPullFormat.contextLine(
            tag: "  ",
            side: .unspecified,
            recordedAt: now.addingTimeInterval(-60),
            now: now,
            locale: Locale(identifier: "en_US")
        )
        XCTAssertFalse(bare.contains("·"), bare)
        XCTAssertFalse(bare.isEmpty)
    }

    // MARK: Source helpers (same private shape as the other wiring suites)

    private func source(_ relativePath: String) -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileURL = packageRoot.appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            XCTFail("Could not read source invariant file: \(fileURL.path): \(error)")
            return ""
        }
    }

    private func code(_ source: String) -> String {
        let withoutBlockComments = source.replacingOccurrences(
            of: #"(?s)/\*.*?\*/"#,
            with: "",
            options: .regularExpression
        )
        return withoutBlockComments
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? "" }
            .joined(separator: "\n")
    }

    private func normalizeWhitespace(_ source: String) -> String {
        source
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
