import XCTest
@testable import SendmeterCore
import SendLogWatchCore

final class GaugeSessionRPETests: XCTestCase {
    private func makeRecording(
        recordedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        durationMilliseconds: Int = 10_000,
        peakKilograms: Double? = 48,
        tag: String = "20 mm",
        zone: RecordedZone? = nil,
        protocolMode: ForceProtocolMode = .hold
    ) -> TindeqRecording {
        TindeqRecording(
            id: UUID(),
            recordedAt: recordedAt,
            durationMilliseconds: durationMilliseconds,
            peakKilograms: peakKilograms,
            averageKilograms: 30,
            sampleCount: 100,
            note: "",
            tag: tag,
            side: .left,
            groupID: nil,
            zone: zone,
            protocolMode: protocolMode
        )
    }

    // MARK: Parity vectors (shared with web + watch via RPEDepletion)

    func testOneBatteryOnCurvePredictsRpe4() {
        let curve = TagForceCurve(tag: "20 mm", modality: "static", cf: 30, wPrime: 180)
        let predicted = GaugeSessionRPE.predict(
            recordings: [makeRecording(peakKilograms: 48)],
            curves: [curve]
        )
        XCTAssertEqual(predicted.rpe, 4, accuracy: 0.1)
        XCTAssertTrue(predicted.fromCurve)
        XCTAssertEqual(predicted.load ?? 0, 1, accuracy: 1e-9)
    }

    func testMixedTagSessionSumsDepletionPerTag() {
        let curves = [
            TagForceCurve(tag: "20 mm", modality: "static", cf: 30, wPrime: 180),
            TagForceCurve(tag: "pinch", modality: "static", cf: 20, wPrime: 100)
        ]
        let predicted = GaugeSessionRPE.predict(
            recordings: [
                makeRecording(peakKilograms: 48, tag: "20 mm"),
                makeRecording(durationMilliseconds: 5_000, peakKilograms: 30, tag: "pinch")
            ],
            curves: curves
        )
        XCTAssertEqual(predicted.load ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(predicted.rpe, 5.1, accuracy: 0.1)
        XCTAssertTrue(predicted.fromCurve)
    }

    func testNoUsableCurveFallsBackToFiveUnconfirmed() {
        let predicted = GaugeSessionRPE.predict(
            recordings: [
                makeRecording(peakKilograms: 48),
                makeRecording(peakKilograms: 60)
            ],
            curves: [TagForceCurve(tag: "20 mm", modality: "static", cf: 0, wPrime: 0)]
        )
        XCTAssertEqual(predicted.rpe, 5)
        XCTAssertFalse(predicted.fromCurve)
        XCTAssertNil(predicted.load)
    }

    func testEmptySessionFallsBack() {
        let predicted = GaugeSessionRPE.predict(recordings: [], curves: [])
        XCTAssertEqual(predicted.rpe, 5)
        XCTAssertFalse(predicted.fromCurve)
    }

    func testLoadMappingMatchesSharedParityFixture() {
        XCTAssertEqual(RPEDepletion.rpeForDepletion(0), 1, accuracy: 1e-9)
        XCTAssertEqual(RPEDepletion.rpeForDepletion(0.5), 2.6, accuracy: 0.1)
        XCTAssertEqual(RPEDepletion.rpeForDepletion(1), 4, accuracy: 0.1)
        XCTAssertEqual(RPEDepletion.rpeForDepletion(2), 6, accuracy: 0.1)
        XCTAssertEqual(RPEDepletion.rpeForDepletion(4), 8.2, accuracy: 0.1)
        XCTAssertEqual(RPEDepletion.rpeForDepletion(6), 9.2, accuracy: 0.1)
    }

    // MARK: Prehab (known-minimal) semantics — the web-only distinction

    func testPrehabOnlySessionIsMeasuredZeroNotFallback() {
        let predicted = GaugeSessionRPE.predict(
            recordings: [makeRecording(zone: .prehab), makeRecording(zone: .prehab)],
            curves: []
        )
        XCTAssertEqual(predicted.rpe, 1, accuracy: 1e-9)
        XCTAssertTrue(predicted.fromCurve)
        XCTAssertEqual(predicted.load ?? 1, 0, accuracy: 1e-9)
    }

    func testPrehabAddsZeroToMeasuredEffortLoad() {
        let curve = TagForceCurve(tag: "20 mm", modality: "static", cf: 30, wPrime: 180)
        let predicted = GaugeSessionRPE.predict(
            recordings: [
                makeRecording(peakKilograms: 48, tag: "20 mm"),
                makeRecording(zone: .prehab)
            ],
            curves: [curve]
        )
        XCTAssertEqual(predicted.load ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(predicted.rpe, 4, accuracy: 0.1)
    }

    func testUnmeasuredEffortWithPrehabRepIsZeroNotFallback() {
        let predicted = GaugeSessionRPE.predict(
            recordings: [
                makeRecording(peakKilograms: 60),
                makeRecording(zone: .prehab)
            ],
            curves: []
        )
        XCTAssertEqual(predicted.rpe, 1, accuracy: 1e-9)
        XCTAssertTrue(predicted.fromCurve)
        XCTAssertEqual(predicted.load ?? 1, 0, accuracy: 1e-9)
    }

    func testPrehabWithoutFittedCurveNeverCountsAsFallback() {
        let predicted = GaugeSessionRPE.predict(
            recordings: [makeRecording(zone: .prehab)],
            curves: []
        )
        XCTAssertTrue(predicted.fromCurve)
        XCTAssertEqual(predicted.rpe, 1, accuracy: 1e-9)
    }

    // MARK: Curve resolution per tag AND modality

    func testReverseActionRecordingReadsItsOwnModalityCurve() {
        let staticCurve = TagForceCurve(tag: "edge", modality: "static", cf: 10, wPrime: 50)
        let reverseCurve = TagForceCurve(tag: "edge", modality: "reverse_action", cf: 30, wPrime: 180)
        let predicted = GaugeSessionRPE.predict(
            recordings: [
                makeRecording(peakKilograms: 48, tag: "edge", protocolMode: .reverseAction)
            ],
            curves: [staticCurve, reverseCurve]
        )
        // The static curve would give (48-10)*10/50 = 7.6; the reverse curve 1.0.
        XCTAssertEqual(predicted.load ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(predicted.rpe, 4, accuracy: 0.1)
    }

    func testModalityOf() {
        XCTAssertEqual(GaugeSessionRPE.modality(of: makeRecording()), "static")
        XCTAssertEqual(
            GaugeSessionRPE.modality(of: makeRecording(protocolMode: .reverseAction)),
            "reverse_action"
        )
    }

    // MARK: Duration + note (web parity)

    func testSpanDurationClampsToDbBounds() {
        let first = makeRecording(recordedAt: Date(timeIntervalSince1970: 1_700_000_000), durationMilliseconds: 30_000)
        let last = makeRecording(recordedAt: Date(timeIntervalSince1970: 1_700_000_100), durationMilliseconds: 60_000)
        XCTAssertEqual(GaugeSessionDuration.spanMinutes(recordings: [first, last]), 3)
        XCTAssertNil(GaugeSessionDuration.spanMinutes(recordings: []))
        XCTAssertEqual(GaugeSessionDuration.clamp(minutes: 0.4), 1)
        XCTAssertEqual(GaugeSessionDuration.clamp(minutes: 900), 600)
    }

    func testNoteBuildsCountAndUniqueTags() {
        let note = GaugeSessionNote.build(recordings: [
            makeRecording(tag: "20 mm"),
            makeRecording(tag: "20 mm"),
            makeRecording(tag: "pinch"),
            makeRecording(tag: "")
        ])
        XCTAssertEqual(note, "4 recordings · 20 mm, pinch")
        XCTAssertEqual(GaugeSessionNote.build(recordings: [makeRecording(tag: "")]), "1 recording")
    }
}
