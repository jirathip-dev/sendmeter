import XCTest
@testable import SendmeterCore

/// #902: the zone target-band + adjustable-intensity math, ported from the
/// web's SL-97 suite (`src/lib/force-curve.test.ts` at 6203902~1 — the
/// pre-#857 tree) and pinned against the web's EXACT numbers. The web model
/// fixture is `maxF 40, cf 20, wPrime 300` with the smart Hill fit
/// `{ cf: 20, maxF: 40, tau: 10, p: 1, sse: 1 }`, whose F60 is 23.142857…;
/// every workS / kg expectation below is the web's own.
final class ZoneIntensityTests: XCTestCase {
    private let model = ZoneCurveInput(
        cf: 20,
        maxForce: 40,
        wPrime: 300,
        capabilityFit: ForceCapabilityFit(
            criticalForceKilograms: 20,
            maximumForceKilograms: 40,
            tau: 10,
            exponent: 1,
            sumSquaredError: 1
        )
    )
    private let noCf = ZoneCurveInput(cf: nil, maxForce: 40, wPrime: nil)

    // MARK: - 100% is an exact no-op (SL-97)

    func test100PercentIsAnExactNoOpForEveryZone() {
        for quality in ZoneQuality.allCases {
            let base = ZoneMix.zoneTarget(for: quality, references: model)
            let adjusted = ZoneMix.zoneTarget(for: quality, references: model, intensityPercent: 100)
            XCTAssertEqual(adjusted, base, "\(quality) at 100% must equal the unadjusted target")
            XCTAssertEqual(adjusted?.holdSeconds, ZoneMix.anchorHoldSeconds(quality))
            XCTAssertFalse(adjusted?.basis.contains("intensity") ?? true)
            XCTAssertEqual(adjusted?.adjustedSets, nil)
        }
    }

    // MARK: - kg scales linearly with pct

    func testPowerKilogramsScaleLinearlyWithPercent() {
        let base = tryUnwrap(ZoneMix.zoneTarget(for: .power, references: model))
        let at80 = tryUnwrap(ZoneMix.zoneTarget(for: .power, references: model, intensityPercent: 80))
        // Web: targetKg 38 × 0.8 → 30.4; low 36 × 0.8 → 28.8; high 40 × 0.8 → 32.
        XCTAssertEqual(at80.targetKilograms, 30.4, accuracy: 0.05)
        XCTAssertEqual(at80.lowKilograms, 28.8, accuracy: 0.05)
        XCTAssertEqual(at80.highKilograms, 32.0, accuracy: 0.05)
        XCTAssertLessThan(abs(at80.targetKilograms - base.targetKilograms * 0.8), 0.05)
        XCTAssertTrue(at80.basis.contains("intensity 80%"))
    }

    // MARK: - W′-cost invariant (hand-built model, cf = 10)

    func testStrengthHoldAtReducedIntensityMatchesWPrimeCostInvariant() {
        let m = ZoneCurveInput(cf: 10, maxForce: 40, wPrime: 200)
        let t68 = tryUnwrap(ZoneMix.zoneTarget(for: .strength, references: m, intensityPercent: 68))
        // targetKg(100%) = 34, cf = 10 → base W′ cost = (34 − 10) × 10s = 240 kg·s.
        XCTAssertEqual(t68.targetKilograms, 23.1, accuracy: 0.05) // 34 × 0.68
        XCTAssertEqual(t68.holdSeconds, 18) // (34−10)×10 / (23.1−10) ≈ 18.3 → round to 18
        // The recovered W′ cost stays close to the 240 baseline despite rounding.
        let recoveredCost = (t68.targetKilograms - 10) * Double(t68.holdSeconds)
        XCTAssertGreaterThan(recoveredCost, 220)
        XCTAssertLessThan(recoveredCost, 260)
    }

    // MARK: - Clamps

    func testHoldClampsAtZoneMaxWhenScaledTargetDropsToOrBelowCF() {
        let m = ZoneCurveInput(cf: 30, maxForce: 40, wPrime: 100)
        XCTAssertEqual(ZoneMix.zoneTarget(for: .strength, references: m, intensityPercent: 60)?.holdSeconds, 30)
        XCTAssertEqual(ZoneMix.zoneTarget(for: .power, references: m, intensityPercent: 60)?.holdSeconds, 15)
    }

    func testHoldFallsBackToImpulseFormulaWithoutCFFit() {
        let t70 = tryUnwrap(ZoneMix.zoneTarget(for: .strength, references: noCf, intensityPercent: 70))
        XCTAssertEqual(t70.targetKilograms, 23.8, accuracy: 0.05) // 34 × 0.7
        XCTAssertEqual(t70.holdSeconds, 14) // 10 × 34 / 23.8 ≈ 14.29 → round to 14
        // Power/strength still resolve without a CF fit.
        XCTAssertNotNil(ZoneMix.zoneTarget(for: .power, references: noCf, intensityPercent: 70))
    }

    // MARK: - Endurance TUT heuristic (sets shrink, reps stays 1)

    func testEnduranceKeepsTUTConstantAndSetsShrinkToCompensate() {
        let t60 = tryUnwrap(ZoneMix.zoneTarget(for: .endurance, references: model, intensityPercent: 60))
        XCTAssertEqual(t60.holdSeconds, 85) // 30 × (100/60)² ≈ 83.3 → round to nearest 5
        XCTAssertEqual(t60.adjustedSets, 3) // round(8 × 30 / 85) = 3
        // Base TUT was 30 × 8 = 240s; rounding keeps it in the ballpark.
        let tut = Double(t60.holdSeconds) * Double(t60.adjustedSets ?? 8)
        XCTAssertGreaterThan(tut, 200)
        XCTAssertLessThan(tut, 280)
        XCTAssertLessThanOrEqual(t60.adjustedSets ?? 8, ZoneMix.zoneProtocols[.endurance]?.sets ?? 8)
    }

    func testEndurance100ReturnsTheFlippedOneByEightShape() {
        let t100 = tryUnwrap(ZoneMix.zoneTarget(for: .endurance, references: model, intensityPercent: 100))
        XCTAssertEqual(t100.holdSeconds, 30)
        XCTAssertNil(t100.adjustedSets) // unchanged = nil (100% no-op)
        XCTAssertEqual(t100.lowKilograms, 16.0, accuracy: 0.05) // cf × 0.8
        XCTAssertEqual(t100.targetKilograms, 18.0, accuracy: 0.05) // cf × 0.9
        XCTAssertEqual(t100.highKilograms, 20.0, accuracy: 0.05) // cf × 1.0
    }

    func testAdjustedEnduranceClampsHoldTo20Through240Seconds() {
        XCTAssertGreaterThanOrEqual(
            ZoneMix.adjustedEndurance(baseHoldSeconds: 30, baseSets: 8, intensityPercent: 110).holdSeconds,
            20
        )
        // An extreme drop (well beyond the UI's 60% floor) hits the 240s cap.
        let extreme = ZoneMix.adjustedEndurance(baseHoldSeconds: 30, baseSets: 8, intensityPercent: 5)
        XCTAssertEqual(extreme.holdSeconds, 240)
        XCTAssertEqual(extreme.sets, 1)
    }

    // MARK: - Input pct clamp to [60, 110]

    func testClampsInputPercentToTheZoneDialRange() {
        let atMax = ZoneMix.zoneTarget(for: .power, references: model, intensityPercent: 200)
        let atMin = ZoneMix.zoneTarget(for: .power, references: model, intensityPercent: -50)
        XCTAssertEqual(atMax, ZoneMix.zoneTarget(for: .power, references: model, intensityPercent: 110))
        XCTAssertEqual(atMin, ZoneMix.zoneTarget(for: .power, references: model, intensityPercent: 60))
    }

    // MARK: - Honest no-reference state

    func testZoneTargetReturnsNilWhenTheQualityReferenceIsUnusable() {
        XCTAssertNil(ZoneMix.zoneTarget(for: .endurance, references: noCf, intensityPercent: 80))
        XCTAssertNil(ZoneMix.zoneTarget(for: .powerEndurance, references: noCf, intensityPercent: 80))
        let noMaxForce = ZoneCurveInput(cf: 20, maxForce: nil, wPrime: 300)
        XCTAssertNil(ZoneMix.zoneTarget(for: .power, references: noMaxForce))
        XCTAssertNil(ZoneMix.zoneTarget(for: .strength, references: noMaxForce))
        // An invalid hill fit (maxF not above cf) never yields an F60.
        let badFit = ZoneCurveInput(
            cf: 20,
            maxForce: 40,
            wPrime: 300,
            capabilityFit: ForceCapabilityFit(
                criticalForceKilograms: 40,
                maximumForceKilograms: 40,
                tau: 10,
                exponent: 1,
                sumSquaredError: 1
            )
        )
        XCTAssertNil(badFit.f60Kilograms)
        XCTAssertNil(ZoneMix.zoneTarget(for: .powerEndurance, references: badFit))
    }

    // MARK: - pct > 100 shortens the hold for every above-CF zone (#105/SL-103)

    func testPower110ShortensTheFiveSecondBaseHold() {
        // baseKg 38 (0.95×40), newKg 41.8 (×1.1) → (18×5)/21.8 ≈ 4.13s → round to 4
        let t = tryUnwrap(ZoneMix.zoneTarget(for: .power, references: model, intensityPercent: 110))
        XCTAssertEqual(t.holdSeconds, 4)
        XCTAssertLessThan(t.holdSeconds, ZoneMix.zoneProtocols[.power]?.holdSeconds ?? 5)
    }

    func testStrength110ShortensTheTenSecondBaseHold() {
        // baseKg 34 (0.85×40), newKg 37.4 → (14×10)/17.4 ≈ 8.05s → round to 8
        let t = tryUnwrap(ZoneMix.zoneTarget(for: .strength, references: model, intensityPercent: 110))
        XCTAssertEqual(t.holdSeconds, 8)
        XCTAssertLessThan(t.holdSeconds, ZoneMix.zoneProtocols[.strength]?.holdSeconds ?? 10)
    }

    func testPowerEndurance110ShortensTheSevenSecondBaseHold() {
        // f60 23.142857… → base 23.1, newKg 25.4 → (3.1×7)/5.4 ≈ 4.02s → the
        // PE [5, 15]s floor engages → 5.
        let t = tryUnwrap(ZoneMix.zoneTarget(for: .powerEndurance, references: model, intensityPercent: 110))
        XCTAssertEqual(t.holdSeconds, 5)
        XCTAssertLessThan(t.holdSeconds, ZoneMix.zoneProtocols[.powerEndurance]?.holdSeconds ?? 7)
    }

    func testPowerFloorEngagesWhenWPrimeCostMathWouldGoLower() {
        // baseKg sits just 0.1 kg above CF; 110% collapses the denominator —
        // the raw math wants a sub-1s hold, which the [3, 15]s clamp floors.
        let tight = ZoneCurveInput(cf: 37.9, maxForce: 40, wPrime: 300)
        XCTAssertEqual(ZoneMix.zoneTarget(for: .power, references: tight, intensityPercent: 110)?.holdSeconds, 3)
    }

    func testStrengthFloorEngagesUnderTightMargin() {
        let tight = ZoneCurveInput(cf: 84.9, maxForce: 100, wPrime: 300)
        XCTAssertEqual(ZoneMix.zoneTarget(for: .strength, references: tight, intensityPercent: 110)?.holdSeconds, 5)
    }

    func testPowerEnduranceFloorEngagesUnderTightMargin() {
        // cf 25, wPrime 6 → f60 = 25 + 6.1/61 = 25.1, just above cf.
        let tight = ZoneCurveInput(
            cf: 25,
            maxForce: 40,
            wPrime: 6,
            capabilityFit: ForceCapabilityFit(
                criticalForceKilograms: 25,
                maximumForceKilograms: 28.05,
                tau: 1,
                exponent: 1,
                sumSquaredError: 1
            )
        )
        XCTAssertEqual(ZoneMix.zoneTarget(for: .powerEndurance, references: tight, intensityPercent: 110)?.holdSeconds, 5)
    }

    // MARK: - #902 locked-prototype fixture (S3/S4 contract)

    /// maxF 22.0 kg → Power 100% = 19.8–22.0 kg at 5s hold; at 85% the band
    /// scales to 16.8–18.7 kg with ~7s hold and the module note flips to
    /// "Adjusted from 5s @100%".
    private let fixture = ZoneCurveInput(cf: 10, maxForce: 22, wPrime: 300)

    func testPower100MatchesLockedPrototypeBand() {
        let t = tryUnwrap(ZoneMix.zoneTarget(for: .power, references: fixture, intensityPercent: 100))
        XCTAssertEqual(t.lowKilograms, 19.8)
        XCTAssertEqual(t.highKilograms, 22.0)
        XCTAssertEqual(t.targetKilograms, 20.9, accuracy: 0.05) // 22 × 0.95
        XCTAssertEqual(t.holdSeconds, 5)
        XCTAssertFalse(t.isAdjusted)
        XCTAssertEqual(t.sourceNote, "From maxF 22.0 kg")
        XCTAssertEqual(t.basis, "90–100% of your best short-window force (22.0 kg)")
    }

    func testPower85MatchesLockedPrototypeScaledBandAndHold() {
        let t = tryUnwrap(ZoneMix.zoneTarget(for: .power, references: fixture, intensityPercent: 85))
        XCTAssertEqual(t.lowKilograms, 16.8) // 22 × 0.9 × 0.85
        XCTAssertEqual(t.highKilograms, 18.7) // 22 × 0.85
        XCTAssertEqual(t.targetKilograms, 17.8, accuracy: 0.05) // 20.9 × 0.85
        XCTAssertEqual(t.holdSeconds, 7) // (20.9−10)×5 / (17.8−10) ≈ 6.99 → 7
        XCTAssertEqual(t.exactHoldSeconds, 6.99, accuracy: 0.01)
        XCTAssertTrue(t.isAdjusted)
        XCTAssertEqual(t.sourceNote, "Adjusted from 5s @100%")
        XCTAssertTrue(t.basis.contains("90–100% of your best short-window force (22.0 kg)"))
        XCTAssertTrue(t.basis.contains(" · intensity 85%"))
    }

    // MARK: - Preset wiring (the executed schedule carries the adjustment)

    func testZonePresetAt100KeepsProtocolTimingAndCarriesZoneFields() {
        let preset = ZoneMix.zonePreset(for: .power)
        XCTAssertEqual(preset.name, "Power")
        XCTAssertEqual(preset.holdSeconds, 5)
        XCTAssertEqual(preset.repetitions, 6)
        XCTAssertEqual(preset.sets, 1)
        XCTAssertEqual(preset.restBetweenRepetitionsSeconds, 150)
        XCTAssertEqual(preset.restBetweenSetsSeconds, 0)
        XCTAssertEqual(preset.zoneQuality, .power)
        XCTAssertEqual(preset.zoneIntensityPercent, 100)
    }

    func testZonePresetAdjustsHoldAndSetsWithIntensity() {
        let power85 = ZoneMix.zonePreset(for: .power, intensityPercent: 85, references: fixture)
        XCTAssertEqual(power85.holdSeconds, 7)
        XCTAssertEqual(power85.sets, 1)

        let endurance60 = ZoneMix.zonePreset(
            for: .endurance,
            intensityPercent: 60,
            references: model
        )
        XCTAssertEqual(endurance60.holdSeconds, 85)
        XCTAssertEqual(endurance60.sets, 3)
        XCTAssertEqual(endurance60.repetitions, 1)

        // No usable reference → the schedule honestly stays at the protocol
        // anchor (the band resolver reports no target for the same reason).
        let noRef85 = ZoneMix.zonePreset(for: .power, intensityPercent: 85, references: nil)
        XCTAssertEqual(noRef85.holdSeconds, 5)

        // Wild input clamps to the dial.
        XCTAssertEqual(ZoneMix.zonePreset(for: .power, intensityPercent: 500, references: fixture).zoneIntensityPercent, 110)
    }

    // MARK: - Resolution path: preset → side-scoped references → band

    func testForceCurveEngineResolvesZonePresetBandFromReferences() {
        let preset = ZoneMix.zonePreset(for: .power, intensityPercent: 100)
        let references = ForceReferences(
            personalRecordKilograms: 22,
            criticalForceKilograms: 10,
            impulseAboveCriticalForceKilogramSeconds: 300,
            maximumForceKilograms: 22,
            capabilityFit: nil
        )
        let band = tryUnwrap(ForceCurveEngine.targetBand(preset: preset, references: references, setNumber: 1))
        XCTAssertEqual(band.lowKilograms, 19.8)
        XCTAssertEqual(band.highKilograms, 22.0)
        XCTAssertEqual(band.kilograms, 20.9, accuracy: 0.05)
    }

    func testForceCurveEngineReturnsNilForUnusableZoneReference() {
        let preset = ZoneMix.zonePreset(for: .endurance, intensityPercent: 100)
        let noCf = ForceReferences(
            personalRecordKilograms: 22,
            criticalForceKilograms: nil,
            impulseAboveCriticalForceKilogramSeconds: nil,
            maximumForceKilograms: 22,
            capabilityFit: nil
        )
        XCTAssertNil(ForceCurveEngine.targetBand(preset: preset, references: noCf, setNumber: 1))
    }

    private func tryUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) -> T {
        guard let value else {
            XCTFail("Expected non-nil zone target", file: file, line: line)
            fatalError("Unwrap failed")
        }
        return value
    }
}
