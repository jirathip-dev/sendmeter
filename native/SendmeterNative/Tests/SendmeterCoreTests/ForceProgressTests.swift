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

    func testStaticCurveInputsChangedTracksTagAndSideEditsAcrossAllRows() {
        let rows = [
            recording(index: 0, id: stableID(1), tag: "Crimp", side: .left),
            recording(index: 1, id: stableID(2), tag: "Crimp", side: .left)
        ]

        var tagEdited = rows
        tagEdited[0].tag = "Pinch"
        XCTAssertTrue(
            ForceProgress.staticCurveInputsChanged(before: rows, after: tagEdited)
        )

        var sideEdited = rows
        sideEdited[0].side = .right
        XCTAssertTrue(
            ForceProgress.staticCurveInputsChanged(before: rows, after: sideEdited)
        )

        // A refresh sort change does not create a spurious fit while every
        // metadata input is unchanged.
        XCTAssertFalse(
            ForceProgress.staticCurveInputsChanged(
                before: rows,
                after: Array(rows.reversed())
            )
        )
    }

    func testStaticCurveInputsChangedTracksCurveChangePastCompactWindow() {
        let rows = (0..<30).map { index in
            recording(
                index: index,
                id: stableID(index + 1),
                tag: "Crimp",
                side: .left,
                average: 15
            )
        }

        // Index 29 is deliberately outside the old first-24 fingerprint.
        var changed = rows
        changed[29] = recording(
            index: 29,
            id: stableID(30),
            tag: "Crimp",
            side: .left,
            average: 18
        )
        XCTAssertTrue(
            ForceProgress.staticCurveInputsChanged(before: rows, after: changed)
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
        XCTAssertFalse(
            ForceProgress.staticCurveInputsChanged(
                before: rows,
                after: rows.map { row in
                    recording(
                        index: Int(row.recordedAt.timeIntervalSince1970 / 86_400),
                        id: row.id,
                        tag: row.tag,
                        side: row.side,
                        setMetrics: metrics
                    )
                }
            )
        )
    }

    func testProgressInputsChangedTracksEachMovementMetricIndependently() {
        let baseMetrics = ReverseActionMetrics(
            meanKilograms: 12,
            coefficientOfVariationPercent: 3,
            inTargetPercent: 95,
            timeUnderTensionMilliseconds: 20_000,
            driftPercent: -1,
            cadenceAdherencePercent: 98
        )
        let before = recording(
            index: 40,
            id: stableID(401),
            tag: "Crimp",
            side: .left,
            protocolMode: .reverseAction,
            setMetrics: baseMetrics
        )

        let mutations: [(String, (ReverseActionMetrics) -> ReverseActionMetrics)] = [
            ("meanKilograms", { metrics in
                ReverseActionMetrics(
                    meanKilograms: 13,
                    coefficientOfVariationPercent: metrics.coefficientOfVariationPercent,
                    inTargetPercent: metrics.inTargetPercent,
                    timeUnderTensionMilliseconds: metrics.timeUnderTensionMilliseconds,
                    driftPercent: metrics.driftPercent,
                    cadenceAdherencePercent: metrics.cadenceAdherencePercent
                )
            }),
            ("coefficientOfVariationPercent", { metrics in
                ReverseActionMetrics(
                    meanKilograms: metrics.meanKilograms,
                    coefficientOfVariationPercent: 4,
                    inTargetPercent: metrics.inTargetPercent,
                    timeUnderTensionMilliseconds: metrics.timeUnderTensionMilliseconds,
                    driftPercent: metrics.driftPercent,
                    cadenceAdherencePercent: metrics.cadenceAdherencePercent
                )
            }),
            ("inTargetPercent", { metrics in
                ReverseActionMetrics(
                    meanKilograms: metrics.meanKilograms,
                    coefficientOfVariationPercent: metrics.coefficientOfVariationPercent,
                    inTargetPercent: 96,
                    timeUnderTensionMilliseconds: metrics.timeUnderTensionMilliseconds,
                    driftPercent: metrics.driftPercent,
                    cadenceAdherencePercent: metrics.cadenceAdherencePercent
                )
            }),
            ("timeUnderTensionMilliseconds", { metrics in
                ReverseActionMetrics(
                    meanKilograms: metrics.meanKilograms,
                    coefficientOfVariationPercent: metrics.coefficientOfVariationPercent,
                    inTargetPercent: metrics.inTargetPercent,
                    timeUnderTensionMilliseconds: metrics.timeUnderTensionMilliseconds + 1,
                    driftPercent: metrics.driftPercent,
                    cadenceAdherencePercent: metrics.cadenceAdherencePercent
                )
            }),
            ("driftPercent", { metrics in
                ReverseActionMetrics(
                    meanKilograms: metrics.meanKilograms,
                    coefficientOfVariationPercent: metrics.coefficientOfVariationPercent,
                    inTargetPercent: metrics.inTargetPercent,
                    timeUnderTensionMilliseconds: metrics.timeUnderTensionMilliseconds,
                    driftPercent: -2,
                    cadenceAdherencePercent: metrics.cadenceAdherencePercent
                )
            }),
            ("cadenceAdherencePercent", { metrics in
                ReverseActionMetrics(
                    meanKilograms: metrics.meanKilograms,
                    coefficientOfVariationPercent: metrics.coefficientOfVariationPercent,
                    inTargetPercent: metrics.inTargetPercent,
                    timeUnderTensionMilliseconds: metrics.timeUnderTensionMilliseconds,
                    driftPercent: metrics.driftPercent,
                    cadenceAdherencePercent: 99
                )
            })
        ]

        for (field, mutate) in mutations {
            let after = recording(
                index: 40,
                id: stableID(401),
                tag: "Crimp",
                side: .left,
                protocolMode: .reverseAction,
                setMetrics: mutate(baseMetrics)
            )
            XCTAssertFalse(
                ForceProgress.staticCurveInputsChanged(before: [before], after: [after]),
                "Static identity changed for Movement field \(field)"
            )
            XCTAssertTrue(
                ForceProgress.progressInputsChanged(before: [before], after: [after]),
                "Progress identity ignored Movement field \(field)"
            )
        }
    }

    func testProgressCardKeyChangesForMovementAndIgnoresDisplayFrames() {
        let baseMetrics = ReverseActionMetrics(
            meanKilograms: 12,
            coefficientOfVariationPercent: 3,
            inTargetPercent: 95,
            timeUnderTensionMilliseconds: 20_000,
            driftPercent: -1,
            cadenceAdherencePercent: 98
        )
        let movementBefore = recording(
            index: 40,
            id: stableID(401),
            tag: "Crimp",
            side: .left,
            protocolMode: .reverseAction,
            setMetrics: baseMetrics
        )
        let changedMetrics = ReverseActionMetrics(
            meanKilograms: baseMetrics.meanKilograms,
            coefficientOfVariationPercent: baseMetrics.coefficientOfVariationPercent,
            inTargetPercent: baseMetrics.inTargetPercent,
            timeUnderTensionMilliseconds: baseMetrics.timeUnderTensionMilliseconds,
            driftPercent: baseMetrics.driftPercent,
            cadenceAdherencePercent: 99
        )
        let movementAfter = recording(
            index: 40,
            id: stableID(401),
            tag: "Crimp",
            side: .left,
            protocolMode: .reverseAction,
            setMetrics: changedMetrics
        )
        XCTAssertTrue(
            ForceProgress.progressInputsChanged(
                before: [movementBefore],
                after: [movementAfter]
            )
        )

        var revision = ForceProgressInputRevision()
        let initialKey = ForceProgressCardKey(
            progressRevision: revision.value,
            selectedTag: "Crimp",
            selectedSide: TindeqSide.left.rawValue,
            hasLoadedRecordings: true,
            curveRevision: 0
        )
        _ = revision.apply(.recordings)
        let afterMovementKey = ForceProgressCardKey(
            progressRevision: revision.value,
            selectedTag: "Crimp",
            selectedSide: TindeqSide.left.rawValue,
            hasLoadedRecordings: true,
            curveRevision: 0
        )
        XCTAssertNotEqual(initialKey, afterMovementKey)

        XCTAssertNotEqual(
            initialKey,
            ForceProgressCardKey(
                progressRevision: initialKey.progressRevision,
                selectedTag: "Pinch",
                selectedSide: initialKey.selectedSide,
                hasLoadedRecordings: initialKey.hasLoadedRecordings,
                curveRevision: initialKey.curveRevision
            )
        )
        XCTAssertNotEqual(
            initialKey,
            ForceProgressCardKey(
                progressRevision: initialKey.progressRevision,
                selectedTag: initialKey.selectedTag,
                selectedSide: TindeqSide.right.rawValue,
                hasLoadedRecordings: initialKey.hasLoadedRecordings,
                curveRevision: initialKey.curveRevision
            )
        )
        XCTAssertNotEqual(
            initialKey,
            ForceProgressCardKey(
                progressRevision: initialKey.progressRevision,
                selectedTag: initialKey.selectedTag,
                selectedSide: initialKey.selectedSide,
                hasLoadedRecordings: false,
                curveRevision: initialKey.curveRevision
            )
        )
        XCTAssertNotEqual(
            initialKey,
            ForceProgressCardKey(
                progressRevision: initialKey.progressRevision,
                selectedTag: initialKey.selectedTag,
                selectedSide: initialKey.selectedSide,
                hasLoadedRecordings: initialKey.hasLoadedRecordings,
                curveRevision: 1
            )
        )

        // Display-only Tindeq samples are not represented by this key. With
        // no model mutation/revision, a new frame leaves the boundary equal.
        let afterDisplayFrame = ForceProgressCardKey(
            progressRevision: revision.value,
            selectedTag: "Crimp",
            selectedSide: TindeqSide.left.rawValue,
            hasLoadedRecordings: true,
            curveRevision: 0
        )
        XCTAssertEqual(afterMovementKey, afterDisplayFrame)

        // A visible primary hero must refresh when its state-specific copy
        // changes (for example, Record a pull → Stop & save). Secondary cards
        // pass nil for the title and retain the stable action-mode identity.
        let visibleRecordAction = ForceProgressCardKey(
            progressRevision: revision.value,
            selectedTag: "Crimp",
            selectedSide: TindeqSide.left.rawValue,
            hasLoadedRecordings: true,
            curveRevision: 0,
            emptyActionKey: "free-pull",
            emptyActionTitle: "Record a pull",
            showsPrimaryEmptyState: true
        )
        let visibleStopAction = ForceProgressCardKey(
            progressRevision: revision.value,
            selectedTag: "Crimp",
            selectedSide: TindeqSide.left.rawValue,
            hasLoadedRecordings: true,
            curveRevision: 0,
            emptyActionKey: "free-pull",
            emptyActionTitle: "Stop & save",
            showsPrimaryEmptyState: true
        )
        XCTAssertNotEqual(visibleRecordAction, visibleStopAction)

        let suppressedRecordAction = ForceProgressCardKey(
            progressRevision: revision.value,
            selectedTag: "Crimp",
            selectedSide: TindeqSide.left.rawValue,
            hasLoadedRecordings: true,
            curveRevision: 0,
            emptyActionKey: "free-pull",
            emptyActionTitle: nil,
            showsPrimaryEmptyState: false
        )
        let suppressedStopAction = ForceProgressCardKey(
            progressRevision: revision.value,
            selectedTag: "Crimp",
            selectedSide: TindeqSide.left.rawValue,
            hasLoadedRecordings: true,
            curveRevision: 0,
            emptyActionKey: "free-pull",
            emptyActionTitle: nil,
            showsPrimaryEmptyState: false
        )
        XCTAssertEqual(suppressedRecordAction, suppressedStopAction)
    }

    func testForceProgressRevisionRestartsCurveKeyAtUploadCompletionBoundary() {
        let account = stableID(100)
        var revision = ForceProgressInputRevision()
        let initial = ForceProgressCurveInputKey(
            selectedTag: "Crimp",
            selectedSide: TindeqSide.left.rawValue,
            revision: revision.value,
            accountUserID: account,
            accountEpoch: 4
        )

        _ = revision.apply(.recordings)
        let afterRecordingMutation = ForceProgressCurveInputKey(
            selectedTag: "Crimp",
            selectedSide: TindeqSide.left.rawValue,
            revision: revision.value,
            accountUserID: account,
            accountEpoch: 4
        )
        XCTAssertNotEqual(initial, afterRecordingMutation)

        // Upload success removes the local sample set after awaited work. It
        // must publish a second revision so a rejected in-flight fit is
        // followed by a fresh SwiftUI task rather than a blank detail.
        let revisionBeforeLocalRemoval = revision.value
        _ = revision.apply(.localSamples)
        XCTAssertGreaterThan(revision.value, revisionBeforeLocalRemoval)
        XCTAssertEqual(revision.localSampleGeneration, 1)
        let afterLocalRemoval = ForceProgressCurveInputKey(
            selectedTag: "Crimp",
            selectedSide: TindeqSide.left.rawValue,
            revision: revision.value,
            accountUserID: account,
            accountEpoch: 4
        )
        XCTAssertNotEqual(afterRecordingMutation, afterLocalRemoval)

        _ = revision.apply(.pendingRecordings)
        XCTAssertNotEqual(
            afterLocalRemoval,
            ForceProgressCurveInputKey(
                selectedTag: "Crimp",
                selectedSide: TindeqSide.left.rawValue,
                revision: revision.value,
                accountUserID: account,
                accountEpoch: 4
            )
        )

        _ = revision.apply(.accountReset)
        XCTAssertNotEqual(revision.value, 0)
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
