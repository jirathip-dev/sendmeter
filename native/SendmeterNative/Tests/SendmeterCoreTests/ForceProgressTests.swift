import XCTest
@testable import SendmeterCore

final class ForceProgressTests: XCTestCase {
    func testStaticProgressUsesTheMeasuredEffortScopeAndKeepsTheUnslicedCount() {
        let base = (0..<10).map { index in
            recording(
                index: index,
                tag: "Crimp",
                side: .left,
                peak: 20 + Double(index),
                average: 15
            )
        }
        let excluded: [TindeqRecording] = [
            recording(index: 20, tag: "Crimp", side: .left, zone: .warmup),
            recording(index: 21, tag: "Crimp", side: .left, protocolMode: .reverseAction),
            recording(index: 22, tag: "Crimp", side: .left, source: .manual),
            recording(index: 23, tag: "Crimp", side: .left, peak: nil),
            recording(index: 24, tag: "Crimp", side: .left, average: nil),
            recording(index: 25, tag: "Pinch", side: .left),
            recording(index: 26, tag: "Crimp", side: .right)
        ]

        let progress = ForceProgress.staticCapacityProgress(
            recordings: Array((excluded + base).reversed()),
            tag: "Crimp",
            side: .left
        )

        XCTAssertEqual(progress.totalCount, 10)
        XCTAssertEqual(progress.recordings.count, 8)
        XCTAssertEqual(progress.recordings.first?.peakKilograms, 22)
        XCTAssertEqual(progress.latestPeakKilograms, 29)
        XCTAssertEqual(progress.bestPeakKilograms, 29)
    }

    func testMovementProgressRequiresMeasuredSetMetricsAndPreservesNativeFields() {
        let metrics = ReverseActionMetrics(
            meanKilograms: 14.5,
            coefficientOfVariationPercent: 4.2,
            inTargetPercent: 93,
            timeUnderTensionMilliseconds: 40_000,
            driftPercent: -3.1,
            cadenceAdherencePercent: 97.5
        )
        let measured = recording(
            index: 1,
            tag: "Crimp",
            side: .left,
            protocolMode: .reverseAction,
            setMetrics: metrics
        )
        let cadenceOnly = recording(
            index: 2,
            tag: "Crimp",
            side: .left,
            protocolMode: .reverseAction
        )
        let staticMetrics = recording(
            index: 3,
            tag: "Crimp",
            side: .left,
            setMetrics: metrics
        )
        let manualMovement = recording(
            index: 4,
            tag: "Crimp",
            side: .left,
            source: .manual,
            protocolMode: .reverseAction,
            setMetrics: metrics
        )

        let progress = ForceProgress.movementProgress(
            recordings: [cadenceOnly, manualMovement, measured, staticMetrics],
            tag: "Crimp",
            side: .left
        )

        XCTAssertEqual(progress.totalCount, 1)
        XCTAssertEqual(progress.recordings, [measured])
        XCTAssertEqual(progress.latestMetrics?.coefficientOfVariationPercent, 4.2)
        XCTAssertEqual(progress.latestMetrics?.driftPercent, -3.1)
        XCTAssertEqual(progress.latestMetrics?.cadenceAdherencePercent, 97.5)
    }

    func testProgressBarsKeepSmallEffortsVisibleAndClampLargeValues() {
        XCTAssertEqual(ForceProgress.barFraction(value: 1, maximum: 10), 0.12, accuracy: 0.0001)
        XCTAssertEqual(ForceProgress.barFraction(value: 5, maximum: 10), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ForceProgress.barFraction(value: 120, maximum: 100), 1, accuracy: 0.0001)
        XCTAssertEqual(ForceProgress.barFraction(value: nil, maximum: 100), 0.12, accuracy: 0.0001)
    }

    private func recording(
        index: Int,
        tag: String,
        side: TindeqSide,
        zone: RecordedZone? = .strength,
        source: RecordingSource = .dynamometer,
        protocolMode: ForceProtocolMode = .hold,
        peak: Double? = 20,
        average: Double? = 15,
        setMetrics: ReverseActionMetrics? = nil
    ) -> TindeqRecording {
        TindeqRecording(
            id: UUID(),
            recordedAt: Date(timeIntervalSince1970: Double(index) * 86_400),
            durationMilliseconds: 10_000,
            peakKilograms: peak,
            averageKilograms: average,
            sampleCount: 10,
            note: "",
            tag: tag,
            side: side,
            groupID: nil,
            zone: zone,
            source: source,
            protocolMode: protocolMode,
            setMetrics: setMetrics
        )
    }
}
