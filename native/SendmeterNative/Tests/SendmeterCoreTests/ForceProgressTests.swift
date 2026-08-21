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

        let evidence = ForceProgress.staticCapacityEvidence(
            recordings: Array((excluded + base).reversed()),
            tag: "Crimp",
            side: .left
        )

        // The full detail trend keeps every selected Static row; only the
        // compact tile's recent window is limited to eight. Curve candidates
        // use that same tag/side scope and never widen to the right side or a
        // reverse-action row.
        XCTAssertEqual(evidence.trendRecordings.count, 10)
        XCTAssertEqual(evidence.recentRecordings.count, 8)
        XCTAssertEqual(evidence.curveFitRecordings.count, 10)
        XCTAssertTrue(evidence.curveFitRecordings.allSatisfy { $0.side == .left })
        XCTAssertTrue(evidence.curveFitRecordings.allSatisfy { $0.protocolMode == .hold })

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

    func testStaticCurveInputIdentityTracksTagAndSideEditsAcrossAllRows() {
        let rows = [
            recording(index: 0, id: stableID(1), tag: "Crimp", side: .left),
            recording(index: 1, id: stableID(2), tag: "Crimp", side: .left)
        ]
        let baseline = ForceProgress.staticCurveInputIdentity(
            recordings: rows,
            tag: "Crimp",
            side: .left
        )

        var tagEdited = rows
        tagEdited[0].tag = "Pinch"
        XCTAssertNotEqual(
            baseline,
            ForceProgress.staticCurveInputIdentity(
                recordings: tagEdited,
                tag: "Crimp",
                side: .left
            )
        )

        var sideEdited = rows
        sideEdited[0].side = .right
        XCTAssertNotEqual(
            baseline,
            ForceProgress.staticCurveInputIdentity(
                recordings: sideEdited,
                tag: "Crimp",
                side: .left
            )
        )

        // The identity is order-independent, so a refresh sort change does
        // not create a spurious fit while every metadata input is unchanged.
        XCTAssertEqual(
            baseline,
            ForceProgress.staticCurveInputIdentity(
                recordings: Array(rows.reversed()),
                tag: "Crimp",
                side: .left
            )
        )
    }

    func testStaticCurveInputIdentityTracksCurveChangePastCompactWindow() {
        let rows = (0..<30).map { index in
            recording(
                index: index,
                id: stableID(index + 1),
                tag: "Crimp",
                side: .left,
                average: 15
            )
        }
        let baseline = ForceProgress.staticCurveInputIdentity(
            recordings: rows,
            tag: "Crimp",
            side: .left
        )

        // Index 29 is deliberately outside the old first-24 fingerprint.
        var changed = rows
        changed[29] = recording(
            index: 29,
            id: stableID(30),
            tag: "Crimp",
            side: .left,
            average: 18
        )
        XCTAssertNotEqual(
            baseline,
            ForceProgress.staticCurveInputIdentity(
                recordings: changed,
                tag: "Crimp",
                side: .left
            )
        )

        // Set execution metrics do not participate in Static evidence or its
        // fitter, so changing that unrelated field need not churn the task.
        let metrics = ReverseActionMetrics(
            meanKilograms: 12,
            coefficientOfVariationPercent: 3,
            inTargetPercent: 95,
            timeUnderTensionMilliseconds: 20_000,
            driftPercent: -1,
            cadenceAdherencePercent: 98
        )
        XCTAssertEqual(
            baseline,
            ForceProgress.staticCurveInputIdentity(
                recordings: rows.map { row in
                    recording(
                        index: Int(row.recordedAt.timeIntervalSince1970 / 86_400),
                        id: row.id,
                        tag: row.tag,
                        side: row.side,
                        setMetrics: metrics
                    )
                },
                tag: "Crimp",
                side: .left
            )
        )
    }

    func testStaticCurveInputIdentityIncludesPendingSamplesAndAccountGeneration() {
        let row = recording(index: 1, id: stableID(1), tag: "Crimp", side: .left)
        let pendingID = stableID(2)
        let accountA = stableID(100)
        let baseline = ForceProgress.staticCurveInputIdentity(
            recordings: [row],
            tag: "Crimp",
            side: .left,
            pendingRecordingIDs: [],
            locallyAvailableSampleIDs: [],
            localSampleGeneration: 1,
            accountUserID: accountA,
            accountEpoch: 4
        )

        XCTAssertNotEqual(
            baseline,
            ForceProgress.staticCurveInputIdentity(
                recordings: [row],
                tag: "Crimp",
                side: .left,
                pendingRecordingIDs: [pendingID],
                locallyAvailableSampleIDs: [pendingID],
                localSampleGeneration: 1,
                accountUserID: accountA,
                accountEpoch: 4
            )
        )
        XCTAssertNotEqual(
            baseline,
            ForceProgress.staticCurveInputIdentity(
                recordings: [row],
                tag: "Crimp",
                side: .left,
                localSampleGeneration: 2,
                accountUserID: accountA,
                accountEpoch: 4
            )
        )
        XCTAssertNotEqual(
            baseline,
            ForceProgress.staticCurveInputIdentity(
                recordings: [row],
                tag: "Crimp",
                side: .left,
                accountUserID: stableID(101),
                accountEpoch: 5
            )
        )
    }

    private func recording(
        index: Int,
        id: UUID? = nil,
        tag: String,
        side: TindeqSide,
        zone: RecordedZone? = .strength,
        source: RecordingSource = .dynamometer,
        protocolMode: ForceProtocolMode = .hold,
        peak: Double? = 20,
        average: Double? = 15,
        durationMilliseconds: Int = 10_000,
        sampleCount: Int = 10,
        note: String = "",
        protocolRunID: UUID? = nil,
        rejected: Bool = false,
        setMetrics: ReverseActionMetrics? = nil
    ) -> TindeqRecording {
        TindeqRecording(
            id: id ?? UUID(),
            recordedAt: Date(timeIntervalSince1970: Double(index) * 86_400),
            durationMilliseconds: durationMilliseconds,
            peakKilograms: peak,
            averageKilograms: average,
            sampleCount: sampleCount,
            note: note,
            tag: tag,
            side: side,
            groupID: nil,
            protocolRunID: protocolRunID,
            zone: zone,
            source: source,
            protocolMode: protocolMode,
            setMetrics: setMetrics,
            rejected: rejected
        )
    }

    private func stableID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
