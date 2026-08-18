import XCTest
@testable import SendmeterCore

/// #653 — pins the training-balance + Focus-Next math to the web's numeric
/// behavior (`src/lib/zoneHistory.test.ts`): `zoneTrainingSets` mirrors the
/// 28-day window + capacity→endurance bucketing, and `recommendZone` mirrors
/// the tie band, the argmin-over-tied pick (not `tied[0]`), and the
/// CF/peak curve bias.
final class TrainingBalanceTests: XCTestCase {
    // MARK: Recording builders

    private func recording(
        id: String,
        recordedAt: Date,
        durationMs: Int,
        zone: RecordedZone? = nil,
        tag: String = "Crimps"
    ) -> TindeqRecording {
        TindeqRecording(
            id: UUID(uuidString: id)!,
            recordedAt: recordedAt,
            durationMilliseconds: durationMs,
            peakKilograms: 20,
            averageKilograms: 18,
            sampleCount: 10,
            note: "",
            tag: tag,
            side: .unspecified,
            groupID: nil,
            zone: zone
        )
    }

    private func recording(iso: String, durationMs: Int, zone: RecordedZone? = nil) -> TindeqRecording {
        let date = ISO8601DateFormatter().date(from: iso)!
        return recording(id: "00000000-0000-0000-0000-00000000000A", recordedAt: date, durationMs: durationMs, zone: zone)
    }

    private let now = ISO8601DateFormatter().date(from: "2026-07-21T12:00:00Z")!

    // MARK: zoneTrainingSets (#182 / SL-100 window)

    func testZoneTrainingSetsSumsHoldTimeNormalisedByProtocolSetLength() {
        let sets = ZoneMix.zoneTrainingSets(
            [
                recording(iso: "2026-07-20T10:00:00Z", durationMs: 5_000),   // power 5s
                recording(iso: "2026-07-20T10:05:00Z", durationMs: 5_200),   // power 5.2s, same day
                recording(iso: "2026-07-19T10:00:00Z", durationMs: 5_000),   // power 5s, different day → 15.2s total
                recording(iso: "2026-07-18T10:00:00Z", durationMs: 30_000),  // endurance 30s
            ],
            now: now
        )
        XCTAssertEqual(sets[.power] ?? 0, 15.2 / 30, accuracy: 1e-12)
        XCTAssertEqual(sets[.endurance] ?? 0, 30.0 / 240, accuracy: 1e-12)
        XCTAssertEqual(sets[.strength] ?? 0, 0)
    }

    func testZoneTrainingSetsIgnoresHoldsOlderThanTheWindow() {
        let sets = ZoneMix.zoneTrainingSets(
            [recording(iso: "2026-05-01T10:00:00Z", durationMs: 5_000)],
            now: now,
            windowDays: 28
        )
        XCTAssertEqual(sets[.power] ?? 0, 0)
    }

    func testZoneTrainingSetsKeepsRecordingExactlyAtTheCutoff() {
        // 28 days × 86_400s before 2026-07-21T12:00:00Z = 2026-06-23T12:00:00Z.
        let boundary = now.addingTimeInterval(-28 * 86_400)
        let sets = ZoneMix.zoneTrainingSets(
            [recording(id: "00000000-0000-0000-0000-00000000000A", recordedAt: boundary, durationMs: 5_000, zone: .power)],
            now: now
        )
        XCTAssertEqual(sets[.power] ?? 0, 5.0 / 30.0, accuracy: 1e-12)
    }

    func testZoneTrainingSetsExcludesInWindowPrehab() {
        let sets = ZoneMix.zoneTrainingSets(
            [recording(iso: "2026-07-20T10:00:00Z", durationMs: 30_000, zone: .prehab)],
            now: now
        )
        XCTAssertEqual(sets.values.reduce(0, +), 0)
    }

    func testCapacityZoneInsideWindowCountsTowardEnduranceAndOutsideIsExcluded() {
        // #657 parity: capacity-zone seconds map to endurance.
        let inside = ZoneMix.zoneTrainingSets(
            [recording(iso: "2026-07-20T10:00:00Z", durationMs: 60_000, zone: .capacity)],
            now: now
        )
        XCTAssertEqual(inside[.endurance] ?? 0, 60.0 / 240.0, accuracy: 1e-12)
        XCTAssertEqual(inside[.power] ?? 0, 0)

        let outside = ZoneMix.zoneTrainingSets(
            [recording(iso: "2026-05-01T10:00:00Z", durationMs: 60_000, zone: .capacity)],
            now: now
        )
        XCTAssertEqual(outside[.endurance] ?? 0, 0)
    }

    // MARK: recommendZone — least-trained (SL-100)

    func testRecommendZoneReturnsNilWithNoTrainingAtAll() {
        XCTAssertNil(ZoneMix.recommendZone(
            sets: [.power: 0, .strength: 0, .powerEndurance: 0, .endurance: 0],
            model: nil
        ))
    }

    func testRecommendZonePicksTheLeastTrainedZone() {
        let rec = ZoneMix.recommendZone(
            sets: [.power: 3, .strength: 2, .powerEndurance: 1, .endurance: 0],
            model: nil
        )
        XCTAssertEqual(rec?.zone, .endurance)
        XCTAssertTrue(rec?.reason.contains("0 endurance sets") == true)
    }

    func testRecommendZoneWithNoBiasPicksTrueMinimumAmongBandedCandidatesNotFirstInOrder() {
        // All four sit within the 0.5-set tie band, so all are candidates —
        // but the pick must be the actual minimum (strength 1.0), not power
        // merely because ZONE_ORDER lists it first.
        let rec = ZoneMix.recommendZone(
            sets: [.power: 1.2, .strength: 1.0, .powerEndurance: 1.4, .endurance: 1.4],
            model: nil
        )
        XCTAssertEqual(rec?.zone, .strength)
        XCTAssertTrue(rec?.reason.contains("1 strength set") == true)
    }

    func testBiasCanPickWithinBandZoneThatIsNotStrictMinimum() {
        // strength (1.0) is the true minimum; power-endurance (1.3) is within
        // the band and on the endurance side, so a low CF ratio steers to it.
        let rec = ZoneMix.recommendZone(
            sets: [.power: 3, .strength: 1.0, .powerEndurance: 1.3, .endurance: 3],
            model: .init(cf: 20, maxForce: 60, wPrime: 500) // CF 20/60 → 33% (<35%) → endurance side
        )
        XCTAssertEqual(rec?.zone, .powerEndurance)
    }

    func testBreaksTiesTowardEnduranceWhenCFIsLowFractionOfPeak() {
        // power & endurance tied at 0; CF 20 of 60 peak → 33% (<35%) → endurance.
        let rec = ZoneMix.recommendZone(
            sets: [.power: 0, .strength: 2, .powerEndurance: 2, .endurance: 0],
            model: .init(cf: 20, maxForce: 60, wPrime: 500)
        )
        XCTAssertEqual(rec?.zone, .endurance)
        XCTAssertTrue(rec?.reason.contains("CF is 33% of peak") == true)
    }

    func testBreaksTiesTowardStrengthWhenCFIsHighFractionOfPeak() {
        // power & endurance tied at 0; CF 45 of 60 → 75% (>35%) → power.
        let rec = ZoneMix.recommendZone(
            sets: [.power: 0, .strength: 2, .powerEndurance: 2, .endurance: 0],
            model: .init(cf: 45, maxForce: 60, wPrime: 500)
        )
        XCTAssertEqual(rec?.zone, .power)
    }

    // MARK: recommendZone — explanation payload (#214)

    func testDetailReportsCandidatesAndMinimumThePickCameFrom() {
        let rec = ZoneMix.recommendZone(
            sets: [.power: 3, .strength: 2, .powerEndurance: 1, .endurance: 0],
            model: nil
        )
        XCTAssertEqual(rec?.detail.minSets, 0)
        XCTAssertEqual(rec?.detail.tied, [.endurance])
        XCTAssertEqual(rec?.detail.unbiasedZone, .endurance)
        XCTAssertNil(rec?.detail.curveRatio)
        XCTAssertNil(rec?.detail.curveBias)
        XCTAssertEqual(rec?.detail.biasChangedPick, false)
    }

    func testDetailReportsCurveRatioAndWhetherItMovedThePick() {
        let rec = ZoneMix.recommendZone(
            sets: [.power: 0, .strength: 2, .powerEndurance: 2, .endurance: 0],
            model: .init(cf: 20, maxForce: 60, wPrime: 500) // 33% → endurance side
        )
        XCTAssertEqual(rec?.zone, .endurance)
        XCTAssertEqual(rec?.detail.tied, [.power, .endurance])
        // Unbiased, the tie between two zeros resolves to power (first-seen
        // minimum); the curve moved it to endurance.
        XCTAssertEqual(rec?.detail.unbiasedZone, .power)
        XCTAssertEqual(rec?.detail.curveRatio ?? 0, 20.0 / 60.0, accuracy: 1e-12)
        XCTAssertEqual(rec?.detail.curveBias, .endurance)
        XCTAssertEqual(rec?.detail.biasChangedPick, true)
    }

    func testDetailSaysCurveDidNotMovePickWhenItAgreesWithUnbiased() {
        let rec = ZoneMix.recommendZone(
            sets: [.power: 0, .strength: 2, .powerEndurance: 2, .endurance: 0],
            model: .init(cf: 45, maxForce: 60, wPrime: 500) // 75% → strength side; unbiased already power
        )
        XCTAssertEqual(rec?.zone, .power)
        XCTAssertEqual(rec?.detail.unbiasedZone, .power)
        XCTAssertEqual(rec?.detail.curveBias, .strength)
        XCTAssertEqual(rec?.detail.biasChangedPick, false)
    }

    func testBiasBoundarySitsExactlyAtCurveBiasRatio() {
        // Ratio exactly 0.35 is NOT below the threshold → strength side.
        let at = ZoneMix.recommendZone(
            sets: [.power: 0, .strength: 2, .powerEndurance: 2, .endurance: 0],
            model: .init(cf: ZoneMix.curveBiasRatio * 60, maxForce: 60, wPrime: 500)
        )
        XCTAssertEqual(at?.detail.curveBias, .strength)
        XCTAssertEqual(ZoneMix.tieBandSets, 0.5)
        XCTAssertEqual(ZoneMix.curveBiasRatio, 0.35)
    }

    func testPreferTheLowerOfTwoInBandBiasedZonesNotFirstInOrder() {
        // power-endurance (0.8) is the true minimum → unbiased returns it.
        // power (1.2) and strength (0.9) are both in the band AND on the
        // strength side, so the bias must choose the lower (strength), not
        // `tied.first` (power).
        let rec = ZoneMix.recommendZone(
            sets: [.power: 1.2, .strength: 0.9, .powerEndurance: 0.8, .endurance: 5],
            model: .init(cf: 45, maxForce: 60, wPrime: 500) // 75% → strength side
        )
        XCTAssertEqual(rec?.zone, .strength)
    }

    func testCurveRatioComputedAsCFOverPredictedFiveSecondPeak() {
        // Web: predictForce(model, 5) = min(maxF, cf + wPrime/5); maxF caps it.
        // cf 30, wPrime 100 → cf + 20 = 50 ≤ maxF 60 → ratio 30/50 = 0.6.
        let rec = ZoneMix.recommendZone(
            sets: [.power: 1, .strength: 0, .powerEndurance: 1, .endurance: 1],
            model: .init(cf: 30, maxForce: 60, wPrime: 100)
        )
        XCTAssertEqual(rec?.detail.curveRatio ?? 0, 30.0 / 50.0, accuracy: 1e-12)
        // CF + wPrime/5 exceeds maxF → capped at maxF → ratio 30/60.
        let capped = ZoneMix.recommendZone(
            sets: [.power: 1, .strength: 0, .powerEndurance: 1, .endurance: 1],
            model: .init(cf: 30, maxForce: 60, wPrime: 500)
        )
        XCTAssertEqual(capped?.detail.curveRatio ?? 0, 0.5, accuracy: 1e-12)
    }

    func testMissingWPrimeFallsBackToMaxForcePeakLikeTheWeb() {
        // Web `predictForce`: `cf === null || wPrime === null` → returns maxF.
        // So with cf present and wPrime nil, the peak is maxF and the ratio is
        // cf/maxF — the bias stays active, exactly as on the web.
        let rec = ZoneMix.recommendZone(
            sets: [.power: 0, .strength: 2, .powerEndurance: 2, .endurance: 0],
            model: .init(cf: 20, maxForce: 60, wPrime: nil)
        )
        XCTAssertEqual(rec?.detail.curveRatio ?? 0, 20.0 / 60.0, accuracy: 1e-12)
        XCTAssertEqual(rec?.detail.curveBias, .endurance)
        XCTAssertEqual(rec?.zone, .endurance)
    }

    func testNoPeakAtAllDisablesTheBiasRatherThanGuessing() {
        // The native cached TagForceCurve has no maxF; with no wPrime to build
        // a predicted peak either, no peak exists and the bias must stay off —
        // the pick stands on set counts alone rather than guessing a ratio.
        let rec = ZoneMix.recommendZone(
            sets: [.power: 0, .strength: 2, .powerEndurance: 2, .endurance: 0],
            model: .init(cf: 20, maxForce: nil, wPrime: nil)
        )
        XCTAssertEqual(rec?.zone, .power) // unbiased tie, first-seen minimum
        XCTAssertNil(rec?.detail.curveRatio)
        XCTAssertNil(rec?.detail.curveBias)
    }

    func testTagForceCurveInputCapsPeakLikeTheWeb() {
        // The native cached curve carries the fit's max force; the predicted
        // 5s peak must be capped by it exactly like web `predictForce`.
        // cf 30, wPrime 100 → cf + 20 = 50, maxF 60 → no cap → ratio 30/50.
        let uncapped = ZoneMix.recommendZone(
            sets: [.power: 1, .strength: 0, .powerEndurance: 1, .endurance: 1],
            model: .init(TagForceCurve(tag: "Crimps", modality: "static", cf: 30, wPrime: 100, maxForceKilograms: 60))
        )
        XCTAssertEqual(uncapped?.detail.curveRatio ?? 0, 30.0 / 50.0, accuracy: 1e-12)
        // cf 30, wPrime 300 → cf + 60 = 90, maxF 60 → capped at 60 → ratio 0.5.
        let capped = ZoneMix.recommendZone(
            sets: [.power: 1, .strength: 0, .powerEndurance: 1, .endurance: 1],
            model: .init(TagForceCurve(tag: "Crimps", modality: "static", cf: 30, wPrime: 300, maxForceKilograms: 60))
        )
        XCTAssertEqual(capped?.detail.curveRatio ?? 0, 0.5, accuracy: 1e-12)
        XCTAssertEqual(capped?.detail.curveBias, .strength)
    }

    func testWPrimeZeroComputesPredictedPeakBoundAtCfLikeTheWeb() {
        // Web `predictForce` guards only `wPrime !== null`: with wPrime = 0 the
        // peak is min(maxF, cf + 0) = min(maxF, cf). cf 20, maxF 60 → peak 20 →
        // ratio 1.0 → strength bias. Native must NOT fall back to maxF here
        // (#653 review finding 8).
        let rec = ZoneMix.recommendZone(
            sets: [.power: 0, .strength: 2, .powerEndurance: 2, .endurance: 0],
            model: .init(cf: 20, maxForce: 60, wPrime: 0)
        )
        XCTAssertEqual(rec?.detail.curveRatio ?? 0, 1.0, accuracy: 1e-12)
        XCTAssertEqual(rec?.detail.curveBias, .strength)
        XCTAssertEqual(rec?.zone, .power)
    }

    // MARK: balanceScopeCounts (#325)

    func testBalanceScopeCountsExcludesPrehabFromBothCounts() {
        // 2 trainable holds (1 recorded, 1 inferred) + 2 Prehab holds.
        let counts = ZoneMix.balanceScopeCounts([
            recording(iso: "2026-07-20T10:00:00Z", durationMs: 10_000, zone: .strength),
            recording(iso: "2026-07-20T10:00:00Z", durationMs: 12_000), // inferred as strength
            recording(iso: "2026-07-20T10:00:00Z", durationMs: 30_000, zone: .prehab),
            recording(iso: "2026-07-20T10:00:00Z", durationMs: 30_000, zone: .prehab),
        ])
        XCTAssertEqual(counts.effortCount, 2)
        XCTAssertEqual(counts.recordedCount, 1)
    }

    func testBalanceScopeCountsExcludesWarmup() {
        let counts = ZoneMix.balanceScopeCounts([
            recording(iso: "2026-07-20T10:00:00Z", durationMs: 5_000, zone: .warmup),
            recording(iso: "2026-07-20T10:00:00Z", durationMs: 10_000, zone: .warmup),
        ])
        XCTAssertEqual(counts.effortCount, 0)
        XCTAssertEqual(counts.recordedCount, 0)
    }

    // MARK: zoneBreakdown — bars' arithmetic (#214)

    func testZoneBreakdownMatchesZoneSetsForEveryZone() {
        let recordings: [TindeqRecording] = [
            recording(iso: "2026-07-20T10:00:00Z", durationMs: 5_000, zone: .power),
            recording(iso: "2026-07-20T10:00:00Z", durationMs: 5_200),
            recording(iso: "2026-07-19T10:00:00Z", durationMs: 10_000, zone: .strength),
            recording(iso: "2026-07-18T10:00:00Z", durationMs: 60_000, zone: .capacity),
            recording(iso: "2026-07-18T10:00:00Z", durationMs: 400), // sub-1s blip → unclassified
            recording(iso: "2026-07-18T10:00:00Z", durationMs: 30_000, zone: .warmup),
        ]
        let breakdown = ZoneMix.zoneBreakdown(recordings)
        let sets = ZoneMix.zoneSets(recordings)
        for zone in ZoneQuality.allCases {
            XCTAssertEqual(
                breakdown.zones[zone]?.sets ?? 0,
                sets[zone] ?? 0,
                accuracy: 1e-12,
                "zoneBreakdown must agree with zoneSets for \(zone)"
            )
        }
        XCTAssertEqual(breakdown.unclassified.count, 1)
        XCTAssertEqual(breakdown.excluded.count, 1)
        // The capacity hold counts toward endurance with a recorded source.
        XCTAssertEqual(breakdown.zones[.endurance]?.totalHoldS ?? 0, 60, accuracy: 1e-12)
    }

    // MARK: zonePreset — arming the recommendation

    func testZonePresetMatchesZoneProtocolShapes() {
        let power = ZoneMix.zonePreset(for: .power)
        XCTAssertEqual(power.holdSeconds, 5)
        XCTAssertEqual(power.repetitions, 6)
        XCTAssertEqual(power.sets, 1)

        let strength = ZoneMix.zonePreset(for: .strength)
        XCTAssertEqual(strength.holdSeconds, 10)
        XCTAssertEqual(strength.repetitions, 5)

        let powEnd = ZoneMix.zonePreset(for: .powerEndurance)
        XCTAssertEqual(powEnd.holdSeconds, 7)
        XCTAssertEqual(powEnd.repetitions, 6)
        XCTAssertEqual(powEnd.sets, 4)

        // #320: endurance is modeled as 1 rep × 8 sets, so the recovery is a
        // set boundary — the unit zoneSets normalises against is still 240s.
        let endurance = ZoneMix.zonePreset(for: .endurance)
        XCTAssertEqual(endurance.holdSeconds, 30)
        XCTAssertEqual(endurance.repetitions, 1)
        XCTAssertEqual(endurance.sets, 8)
        XCTAssertEqual(ZoneMix.zoneSetDurationSeconds(.endurance), 240)
    }

    func testRecordedZoneEveryQualityHasAValue() {
        // #653 review finding 1: power-endurance now has a real RecordedZone
        // so a guided PE run's holds carry the zone as a fact instead of being
        // re-inferred from measured duration (hands-free start latency skew).
        XCTAssertEqual(ZoneMix.recordedZone(for: .power), .power)
        XCTAssertEqual(ZoneMix.recordedZone(for: .strength), .strength)
        XCTAssertEqual(ZoneMix.recordedZone(for: .endurance), .endurance)
        XCTAssertEqual(ZoneMix.recordedZone(for: .powerEndurance), .powerEndurance)
    }

    func testRecordedPowerEnduranceZoneWinsOverDuration() {
        // A 5.9s hold recorded as power-endurance (a hands-free PE rep that
        // ramped 1.1s late) must stay power-endurance — never re-inferred as
        // power from duration (#653 review finding 1 direction A).
        let rec = recording(iso: "2026-07-20T10:00:00Z", durationMs: 5_900, zone: .powerEndurance)
        XCTAssertEqual(ZoneMix.zone(for: rec), .powerEndurance)
        XCTAssertEqual(ZoneMix.zoneSets([rec])[.powerEndurance] ?? 0, 5.9 / 42, accuracy: 1e-12)
        XCTAssertEqual(ZoneMix.zoneSets([rec])[.power] ?? 0, 0)
    }

    func testRecordedPowerEnduranceRawValueRoundTrips() {
        // #653 review finding 1 direction B: web-written rows carry the
        // "power-endurance" raw value; it must decode instead of silently
        // becoming nil and being re-inferred by duration.
        XCTAssertEqual(RecordedZone(rawValue: "power-endurance"), .powerEndurance)
        XCTAssertEqual(RecordedZone.powerEndurance.rawValue, "power-endurance")
    }

    func testZoneSetDurationDerivesFromProtocolTable() {
        // #653 review finding 11: the divisor must come from the same
        // protocol table the guided preset is built from, so they can't drift.
        for zone in ZoneQuality.allCases {
            let prescription = ZoneMix.zoneProtocols[zone]!
            let setsFactor = prescription.setDurationIncludesSets
                ? Double(prescription.sets)
                : 1
            let expected = Double(prescription.holdSeconds)
                * Double(prescription.repetitions)
                * setsFactor
            XCTAssertEqual(
                ZoneMix.zoneSetDurationSeconds(zone),
                expected,
                accuracy: 1e-12,
                "\(zone) divisor must match its protocol prescription"
            )
            XCTAssertEqual(prescription.holdSeconds, ZoneMix.anchorHoldSeconds(zone))
        }
    }
}
