import XCTest
@testable import SendmeterCore

final class ZoneMixTests: XCTestCase {
    private func recording(
        id: String,
        durationMs: Int,
        zone: RecordedZone? = nil,
        side: TindeqSide = .unspecified
    ) -> TindeqRecording {
        TindeqRecording(
            id: UUID(uuidString: id)!,
            recordedAt: Date(timeIntervalSince1970: 0),
            durationMilliseconds: durationMs,
            peakKilograms: 20,
            averageKilograms: 18,
            sampleCount: 10,
            note: "",
            tag: "Crimps",
            side: side,
            groupID: nil,
            zone: zone
        )
    }

    // MARK: classifyZone

    func testClassifyZoneBucketsByHoldLength() {
        XCTAssertEqual(ZoneMix.classifyZone(durationSeconds: 1), .power)
        XCTAssertEqual(ZoneMix.classifyZone(durationSeconds: 6), .power)
        XCTAssertEqual(ZoneMix.classifyZone(durationSeconds: 6.5), .powerEndurance)
        XCTAssertEqual(ZoneMix.classifyZone(durationSeconds: 8.5), .powerEndurance)
        XCTAssertEqual(ZoneMix.classifyZone(durationSeconds: 9), .strength)
        XCTAssertEqual(ZoneMix.classifyZone(durationSeconds: 20), .strength)
        XCTAssertEqual(ZoneMix.classifyZone(durationSeconds: 21), .endurance)
    }

    func testClassifyZoneRejectsSubSecondBlips() {
        XCTAssertNil(ZoneMix.classifyZone(durationSeconds: 0.9))
    }

    // MARK: zoneSetDurationSeconds

    func testZoneSetDurationSecondsUsesProtocolReps() {
        XCTAssertEqual(ZoneMix.zoneSetDurationSeconds(.power), 30)
        XCTAssertEqual(ZoneMix.zoneSetDurationSeconds(.strength), 50)
        XCTAssertEqual(ZoneMix.zoneSetDurationSeconds(.powerEndurance), 42)
        // Endurance: holdS × reps × sets (the whole 8-hold protocol, #320).
        XCTAssertEqual(ZoneMix.zoneSetDurationSeconds(.endurance), 240)
    }

    // MARK: zone(for:) — recorded wins, maintenance excluded

    func testRecordedZoneWinsOverDuration() {
        // A 30s hold recorded as Power stays Power (it's a fact about how the
        // hold was performed, not a guess).
        let rec = recording(id: "00000000-0000-0000-0000-00000000000A", durationMs: 30_000, zone: .power)
        XCTAssertEqual(ZoneMix.zone(for: rec), .power)
    }

    func testUnrecordedZoneIsInferredFromDuration() {
        let rec = recording(id: "00000000-0000-0000-0000-00000000000A", durationMs: 10_000)
        XCTAssertEqual(ZoneMix.zone(for: rec), .strength)
    }

    func testMaintenanceZonesAreExcluded() {
        for zone in [RecordedZone.warmup, .prehab] {
            let rec = recording(id: "00000000-0000-0000-0000-00000000000A", durationMs: 10_000, zone: zone)
            XCTAssertNil(ZoneMix.zone(for: rec), "\(zone) must not count toward training balance")
        }
    }

    func testNativeCapacityZoneReadsAsEndurance() {
        let rec = recording(id: "00000000-0000-0000-0000-00000000000A", durationMs: 10_000, zone: .capacity)
        XCTAssertEqual(ZoneMix.zone(for: rec), .endurance)
    }

    // MARK: zoneSets

    func testZoneSetsNormaliseByProtocolSetDuration() {
        // 10s strength → 10/50 = 0.2 sets; 5s power → 5/30 sets.
        let sets = ZoneMix.zoneSets([
            recording(id: "00000000-0000-0000-0000-00000000000A", durationMs: 10_000, zone: .strength),
            recording(id: "00000000-0000-0000-0000-00000000000B", durationMs: 5_000, zone: .power),
        ])
        XCTAssertEqual(sets[.strength], 0.2)
        XCTAssertEqual(sets[.power] ?? 0, 5.0 / 30.0, accuracy: 1e-12)
        XCTAssertEqual(sets[.powerEndurance] ?? 0, 0)
        XCTAssertEqual(sets[.endurance] ?? 0, 0)
    }

    func testZoneSetsExcludesMaintenanceRecordings() {
        let sets = ZoneMix.zoneSets([
            recording(id: "00000000-0000-0000-0000-00000000000A", durationMs: 60_000, zone: .warmup),
        ])
        XCTAssertEqual(sets.values.reduce(0, +), 0)
    }

    // MARK: dominantZone

    func testDominantZonePicksHighestSetCount() {
        let sets: [ZoneQuality: Double] = [.power: 0.1, .strength: 0.8, .powerEndurance: 0.3, .endurance: 0.2]
        XCTAssertEqual(ZoneMix.dominantZone(sets), .strength)
    }

    func testDominantZoneBreaksTiesDeterministically() {
        let sets: [ZoneQuality: Double] = [.power: 0.5, .strength: 0.5, .powerEndurance: 0.1, .endurance: 0.1]
        // zoneOrder is [power, strength, power-endurance, endurance].
        XCTAssertEqual(ZoneMix.dominantZone(sets), .power)
    }

    func testDominantZoneIsNilWhenAllZonesEmpty() {
        XCTAssertNil(ZoneMix.dominantZone([:]))
        XCTAssertNil(ZoneMix.dominantZone([.power: 0, .strength: 0]))
    }

    // MARK: isEffortRecording / isRecoveredRecording / isCurveFitCandidate (#651)

    func testIsEffortRecordingExcludesMaintenanceZones() {
        // A warm-up hold (zone nil via duration inference here) — the
        // 2×10 strength set is an effort, the warm-up is not.
        let warmup = recording(id: "00000000-0000-0000-0000-0000000000A1", durationMs: 10_000)
        let strength = recording(id: "00000000-0000-0000-0000-0000000000A2", durationMs: 20_000, zone: .strength)
        // Duration-inferred warm-up-length hold is sub-1s? No — 10s is
        // strength by duration. Build a genuine warm-up: recorded zone.
        let warmupRecorded = recording(id: "00000000-0000-0000-0000-0000000000A3", durationMs: 10_000, zone: .warmup)
        XCTAssertFalse(ZoneMix.isEffortRecording(warmupRecorded))
        XCTAssertTrue(ZoneMix.isEffortRecording(strength))
        XCTAssertTrue(ZoneMix.isEffortRecording(warmup)) // inferred, not recorded maintenance
    }

    func testIsRecoveredRecordingRequiresConjunction() {
        // Salvage blob: zone nil + protocolRunID nil + matching note.
        let blob = recording(id: "00000000-0000-0000-0000-0000000000B1", durationMs: 120_000)
        let blobWithNote = TindeqRecording(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!,
            recordedAt: Date(timeIntervalSince1970: 0),
            durationMilliseconds: 120_000,
            peakKilograms: 25,
            averageKilograms: 6,
            sampleCount: 100,
            note: "Recovered after sign-out",
            tag: "Crimps",
            side: .unspecified,
            groupID: nil,
            zone: nil
        )
        XCTAssertTrue(ZoneMix.isRecoveredRecording(blobWithNote))
        // A zone keeps it out even with the note (recorded fact wins).
        let zoned = TindeqRecording(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!,
            recordedAt: Date(timeIntervalSince1970: 0),
            durationMilliseconds: 60_000,
            peakKilograms: 25,
            averageKilograms: 6,
            sampleCount: 60,
            note: "Recovered after sign-out",
            tag: "Crimps",
            side: .unspecified,
            groupID: nil,
            zone: .endurance
        )
        XCTAssertFalse(ZoneMix.isRecoveredRecording(zoned))
        // A protocol-run blobs carries protocolRunID → not recovered.
        let withRun = TindeqRecording(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!,
            recordedAt: Date(timeIntervalSince1970: 0),
            durationMilliseconds: 120_000,
            peakKilograms: 25,
            averageKilograms: 6,
            sampleCount: 100,
            note: "Recovered after sign-out",
            tag: "Crimps",
            side: .unspecified,
            groupID: nil,
            protocolRunID: UUID(),
            zone: nil
        )
        XCTAssertFalse(ZoneMix.isRecoveredRecording(withRun))
        // A legit reconstruction (no matching note) still enters the fit.
        let legit = TindeqRecording(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B4")!,
            recordedAt: Date(timeIntervalSince1970: 0),
            durationMilliseconds: 30_000,
            peakKilograms: 30,
            averageKilograms: 24,
            sampleCount: 30,
            note: "Interrupted session — resumed",
            tag: "Crimps",
            side: .unspecified,
            groupID: nil,
            protocolRunID: nil,
            zone: nil
        )
        XCTAssertFalse(ZoneMix.isRecoveredRecording(legit))
        XCTAssertTrue(ZoneMix.isCurveFitCandidate(legit))
    }

    func testCurveFitCandidateExcludesRecoveredBlobButPRKeepsItsPeak() {
        // Warm-up hold (recorded) must NOT be a curve candidate.
        let warmup = recording(id: "00000000-0000-0000-0000-0000000000C1", durationMs: 60_000, zone: .warmup)
        XCTAssertFalse(ZoneMix.isCurveFitCandidate(warmup))

        // Salvage blob: excluded from the fit (isCurveFitCandidate false)…
        let blob = TindeqRecording(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!,
            recordedAt: Date(timeIntervalSince1970: 0),
            durationMilliseconds: 120_000,
            peakKilograms: 28,
            averageKilograms: 6,
            sampleCount: 100,
            note: "Recovered after connection loss",
            tag: "Crimps",
            side: .unspecified,
            groupID: nil,
            zone: nil
        )
        XCTAssertFalse(ZoneMix.isCurveFitCandidate(blob))
        // …but a strength set with peak/avg present IS a candidate.
        let strength = recording(id: "00000000-0000-0000-0000-0000000000C3", durationMs: 20_000, zone: .strength)
        XCTAssertTrue(ZoneMix.isCurveFitCandidate(strength))

        // PR/trend asymmetry (#486): a blob's peakKg still counts for PR —
        // the same peak values the web's effortPeakKg keeps.
        let prCandidates = [blob, strength]
            .filter(ZoneMix.isEffortRecording)
            .compactMap(\.peakKilograms)
        XCTAssertEqual(prCandidates, [28, 20])
    }

    // MARK: maintenancePreset(for:) — Warm-up / Prehab guided presets (#710)

    func testMaintenancePresetWarmupMatchesWebProtocol() {
        // Web `buildWarmupSelection` needs a usable PR (maxF) to build; pass one.
        let preset = ZoneMix.maintenancePreset(for: .warmup, personalRecord: 50)
        XCTAssertEqual(preset?.name, "Warm-up")
        XCTAssertEqual(preset?.holdSeconds, 20)
        XCTAssertEqual(preset?.holdSecondsBySet, [20, 15, 10, 10])
        XCTAssertEqual(preset?.repetitions, 1)
        XCTAssertEqual(preset?.sets, 4)
        XCTAssertEqual(preset?.restBetweenRepetitionsSeconds, 0)
        XCTAssertEqual(preset?.restBetweenSetsSeconds, 60)
        // Web: targetPct 30, pctBasis "pr", pctStep 10.
        XCTAssertEqual(preset?.targetPercentage, 30)
        XCTAssertEqual(preset?.percentageBasis, .personalRecord)
        XCTAssertEqual(preset?.percentageStep, 10)
        XCTAssertEqual(preset?.alternateSides, true)
    }

    func testMaintenancePresetWarmupGatesOnUsablePR() {
        XCTAssertNil(ZoneMix.maintenancePreset(for: .warmup))
        XCTAssertNil(ZoneMix.maintenancePreset(for: .warmup, personalRecord: 0))
    }

    func testMaintenancePresetPrehabMatchesWebProtocol() {
        // Web `buildPrehabSelection` stores a FIXED targetKg (targetPct null,
        // pctBasis "pr") — 0.70 × CF when fitted. Give a CF fit.
        let model = ZoneCurveInput(cf: 10, maxForce: 20, wPrime: 3)
        let preset = ZoneMix.maintenancePreset(for: .prehab, model: model)
        XCTAssertEqual(preset?.name, "Prehab")
        XCTAssertEqual(preset?.holdSeconds, 90)
        XCTAssertEqual(preset?.holdSecondsBySet, [90, 60, 30, 30])
        XCTAssertEqual(preset?.repetitions, 1)
        XCTAssertEqual(preset?.sets, 4)
        XCTAssertEqual(preset?.restBetweenRepetitionsSeconds, 0)
        XCTAssertEqual(preset?.restBetweenSetsSeconds, 20)
        // Web parity: fixed kg, no percentage, pctBasis "pr".
        XCTAssertEqual(preset?.targetKilograms, 7.0)
        XCTAssertNil(preset?.targetPercentage)
        XCTAssertEqual(preset?.percentageBasis, .personalRecord)
        XCTAssertEqual(preset?.alternateSides, true)
    }

    func testMaintenancePresetPrehabFallsBackToMaxFWhenNoCF() {
        // No CF fit but a PR/peak exists — web prehabTarget falls back to
        // 0.30 × maxF. Assert that fallback gave a real target (no targetless run).
        let preset = ZoneMix.maintenancePreset(for: .prehab, personalRecord: 20)
        XCTAssertEqual(preset?.targetKilograms, 6.0)
        XCTAssertEqual(preset?.targetPercentage, nil)
        XCTAssertEqual(preset?.percentageBasis, .personalRecord)
    }

    func testMaintenancePresetPrehabGatesOnUsableReference() {
        // Neither CF nor a PR/peak: the web buildPrehabSelection returns null
        // (the chip is disabled), not a targetless preset.
        XCTAssertNil(ZoneMix.maintenancePreset(for: .prehab))
        XCTAssertNil(ZoneMix.maintenancePreset(for: .prehab, model: ZoneCurveInput(cf: nil, maxForce: nil, wPrime: nil)))
    }

    func testMaintenancePresetOnlyForMaintenanceZones() {
        // The four trainable qualities are NOT maintenance presets — they use
        // `zonePreset(for:)` instead.
        XCTAssertNil(ZoneMix.maintenancePreset(for: .power))
        XCTAssertNil(ZoneMix.maintenancePreset(for: .strength))
        XCTAssertNil(ZoneMix.maintenancePreset(for: .powerEndurance))
        XCTAssertNil(ZoneMix.maintenancePreset(for: .endurance))
        XCTAssertNil(ZoneMix.maintenancePreset(for: .capacity))
    }

    func testPrehabTargetKilogramsWebFallback() {
        // 0.70 × CF (round 1dp); then 0.30 × maxF fallback; nil when neither.
        XCTAssertEqual(ZoneMix.prehabTargetKilograms(cf: 10, maxForce: 20), 7.0)
        XCTAssertEqual(ZoneMix.prehabTargetKilograms(cf: nil, maxForce: 20), 6.0)
        XCTAssertEqual(ZoneMix.prehabTargetKilograms(cf: 0, maxForce: 20), 6.0)
        XCTAssertNil(ZoneMix.prehabTargetKilograms(cf: nil, maxForce: 0))
        XCTAssertNil(ZoneMix.prehabTargetKilograms(cf: nil, maxForce: nil))
    }

    // MARK: #711 — movementPreset() — the transient "Movement Starter"

    func testMovementPresetIsReverseActionStarter() {
        let preset = ZoneMix.movementPreset()
        XCTAssertEqual(preset.protocolMode, .reverseAction)
        XCTAssertEqual(preset.name, "Movement Starter")
        XCTAssertEqual(preset.repetitions, 10)
        XCTAssertEqual(preset.sets, 3)
        XCTAssertEqual(preset.cadenceOutSeconds, 3)
        XCTAssertEqual(preset.cadenceReturnSeconds, 1)
        XCTAssertEqual(preset.restBetweenRepetitionsSeconds, 0)
        XCTAssertEqual(preset.restBetweenSetsSeconds, 60)
        XCTAssertEqual(preset.prepareSeconds, 5)
        XCTAssertEqual(preset.setupNote, MovementTerminology.resistedMovement)
        XCTAssertFalse(preset.targetFromCurve)
        XCTAssertNil(preset.targetKilograms)
        XCTAssertNil(preset.targetPercentage)
    }
}
