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

    /// H1: the drawn thumb and the touch share one mapping — `value(atX:)`
    /// is the inverse of `center`, snapped to 5 % and clamped, so a tick,
    /// the thumb at that value and a touch on the tick all agree.
    func testIntensityTouchMappingInvertsTheTickMapping() {
        for tick in IntensityScale.tickValues {
            let x = IntensityScale.center(value: Double(tick), trackWidth: 300)
            XCTAssertEqual(IntensityScale.value(atX: x, trackWidth: 300), tick)
        }
        // Snaps to the nearest 5 %: 231.6 pt is 100; 3 pt either side stays 100.
        XCTAssertEqual(IntensityScale.value(atX: 228.6, trackWidth: 300), 100)
        XCTAssertEqual(IntensityScale.value(atX: 234.6, trackWidth: 300), 100)
        // Off either end clamps instead of leaving the scale.
        XCTAssertEqual(IntensityScale.value(atX: -40, trackWidth: 300), 60)
        XCTAssertEqual(IntensityScale.value(atX: 900, trackWidth: 300), 110)
        // VoiceOver steps by one 5 % notch, clamped.
        XCTAssertEqual(IntensityScale.stepped(100, by: 1), 105)
        XCTAssertEqual(IntensityScale.stepped(110, by: 1), 110)
        XCTAssertEqual(IntensityScale.stepped(60, by: -1), 60)
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

    // MARK: Free hold chart axis (Conductor sheet review)

    /// Waiting: nothing drawn yet, the Best line must be on the canvas with
    /// round gridlines (the zero-based 36.2 kg top drew 9 / 18 / 27 kg lines).
    func testFreeHoldAxisWaitingShowsTheBestLineOnRoundTicks() {
        let domain = FreeHoldChartDomain(lowKilograms: nil, highKilograms: nil, referenceKilograms: 31.5)
        XCTAssertEqual(domain.lower, 0)
        XCTAssertEqual(domain.upper, 35)
        XCTAssertEqual(domain.ticks, [10, 20, 30])
        XCTAssertEqual(domain.fraction(of: 31.5), 0.9, accuracy: 1e-9)
    }

    /// A late-hold window (26–30 kg) fills the card instead of the top fifth,
    /// the Best line stays inside, and the first label says the axis does not
    /// start at 0.
    func testFreeHoldAxisFitsALateHoldWindow() {
        let domain = FreeHoldChartDomain(lowKilograms: 25.9, highKilograms: 29.8, referenceKilograms: 31.5)
        XCTAssertEqual(domain.lower, 24)
        XCTAssertEqual(domain.upper, 33)
        XCTAssertEqual(domain.ticks, [26, 28, 30, 32])
        XCTAssertEqual(domain.fraction(of: 26.2), 2.2 / 9, accuracy: 1e-9)
        XCTAssertEqual(domain.fraction(of: 31.5), 7.5 / 9, accuracy: 1e-9)
        // The zero-based 0–36.2 axis gave the same window 11 % of the card.
        let spread = domain.fraction(of: 29.8) - domain.fraction(of: 25.9)
        XCTAssertGreaterThan(spread, 0.4, "the window must use the card, not a sliver")
    }

    /// Data that comes near 0 (the first seconds of a pull) keeps a
    /// zero-based axis.
    func testFreeHoldAxisStartsAtZeroWhenTheDrawnDataDoes() {
        let domain = FreeHoldChartDomain(lowKilograms: 0, highKilograms: 30.3, referenceKilograms: 31.5)
        XCTAssertEqual(domain.lower, 0)
        XCTAssertEqual(domain.ticks, [10, 20, 30])
    }

    /// A pull above the Best line still fits itself; a steady hold is never
    /// blown up past the minimum span; ticks are always round and inside.
    func testFreeHoldAxisInvariants() {
        let beats = FreeHoldChartDomain(lowKilograms: 28, highKilograms: 34.2, referenceKilograms: 31.5)
        XCTAssertGreaterThan(beats.upper, 34.2)
        let flat = FreeHoldChartDomain(lowKilograms: 30, highKilograms: 30.4, referenceKilograms: nil)
        XCTAssertGreaterThanOrEqual(flat.upper - flat.lower, FreeHoldChartDomain.minimumSpanKilograms)
        for (low, high, best) in [(0.0, 12.0, 13.0), (70, 82, 80), (9.5, 12, nil), (40, 41, 60)] as [(Double, Double, Double?)] {
            let domain = FreeHoldChartDomain(lowKilograms: low, highKilograms: high, referenceKilograms: best)
            XCTAssertLessThanOrEqual(domain.lower, low)
            XCTAssertGreaterThan(domain.upper, max(high, best ?? 0))
            XCTAssertFalse(domain.ticks.isEmpty)
            XCTAssertLessThanOrEqual((domain.upper - domain.lower) / domain.step, FreeHoldChartDomain.maxSnappedIntervals)
            XCTAssertLessThanOrEqual(domain.ticks.count, ForceTraceScale.maxTicks)
            for tick in domain.ticks {
                XCTAssertGreaterThan(tick, domain.lower)
                XCTAssertLessThan(tick, domain.upper)
                XCTAssertEqual(tick.truncatingRemainder(dividingBy: domain.step), 0, accuracy: 1e-9)
            }
        }
    }

    /// The shared mapping: guided (lower 0) maps exactly as the old
    /// `max(0, kg) / maxValue`, and values under a fitted floor sit on it.
    func testTraceMappingIsTheOldGuidedMappingAtZero() {
        for kilograms in [-3.0, 0, 7.5, 18, 36.2] {
            XCTAssertEqual(
                FreeHoldChartDomain.fraction(of: kilograms, lower: 0, upper: 36.225),
                max(0, kilograms) / 36.225,
                accuracy: 1e-12
            )
        }
        XCTAssertEqual(FreeHoldChartDomain.fraction(of: 12, lower: 20, upper: 35), 0)
    }

    /// Sweep: every Free hold gridline is a whole kilogram (steps 1 / 2 / 5 /
    /// 10 … only, never 2.5 → "27.5" labels), at most four labels, and the
    /// axis always contains the drawn window and the Best line — across
    /// light to heavy pulls, steady to steep windows, with and without Best.
    func testFreeHoldAxisTicksAreWholeKilogramsAcrossTheRange() {
        var offenders: [String] = []
        var cases = 0
        let bests: [Double?] = [nil, 9.0, 13.0, 31.5, 52.0, 84.5]
        for low in stride(from: 0.0, through: 90.0, by: 0.5) {
            for rise in [0.0, 0.4, 1.5, 2.5, 4.0, 6.0, 7.5, 12.0, 25.0, 40.0] {
                for best in bests {
                    cases += 1
                    let high = low + rise
                    let domain = FreeHoldChartDomain(lowKilograms: low, highKilograms: high, referenceKilograms: best)
                    let mantissa = domain.step / pow(10, (log10(domain.step)).rounded(.down))
                    let wholeStep = domain.step >= 1
                        && [1.0, 2.0, 5.0].contains { abs($0 - mantissa) < 1e-9 }
                    let wholeTicks = domain.ticks.allSatisfy { $0 == $0.rounded() }
                    let contains = domain.lower <= low && domain.upper > max(high, best ?? 0)
                    if !wholeStep || !wholeTicks || !contains
                        || domain.ticks.isEmpty || domain.ticks.count > ForceTraceScale.maxTicks {
                        offenders.append("low \(low) high \(high) best \(String(describing: best)): \(domain.lower)–\(domain.upper) step \(domain.step) ticks \(domain.ticks)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(cases, 10_000)
        XCTAssertEqual(offenders.count, 0, "first offenders: \(offenders.prefix(5))")
    }

    /// A saved pull is a ramp from 0 plus a hold: the axis fits the hold, so
    /// the plateau fills the card instead of its top sixth, and the peak is
    /// never cut. Early in a pull, while the ramp is most of the window, the
    /// axis stays zero-based.
    func testHoldExtentFitsTheHoldNotTheRamp() throws {
        let ramp = (0..<24).map { Double($0) * 1.25 }                    // 0 → 28.75 kg in 0.3 s
        let hold = (0..<1_896).map { 29.6 - 3.4 * Double($0) / 1_895 }    // 29.6 → 26.2 kg
        let savedPull = ramp + hold + [30.2]
        let extent = try XCTUnwrap(FreeHoldChartDomain.holdExtent(of: savedPull))
        XCTAssertGreaterThan(extent.low, 26, "the ramp must not set the floor")
        XCTAssertEqual(extent.high, 30.2, "the peak is never cut")
        let domain = FreeHoldChartDomain(lowKilograms: extent.low, highKilograms: extent.high, referenceKilograms: 31.5)
        XCTAssertGreaterThan(domain.lower, 0)
        XCTAssertGreaterThan(domain.fraction(of: 30.2) - domain.fraction(of: 26.2), 0.4)

        let earlyWindow = Array(ramp + hold.prefix(60))                    // 1 s into the pull
        let early = try XCTUnwrap(FreeHoldChartDomain.holdExtent(of: earlyWindow))
        XCTAssertEqual(
            FreeHoldChartDomain(lowKilograms: early.low, highKilograms: early.high, referenceKilograms: 31.5).lower,
            0
        )
        XCTAssertNil(FreeHoldChartDomain.holdExtent(of: []))
    }
}
