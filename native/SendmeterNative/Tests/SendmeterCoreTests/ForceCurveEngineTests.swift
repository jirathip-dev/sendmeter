import XCTest
@testable import SendmeterCore

final class ForceCurveEngineTests: XCTestCase {
    func testMeanMaxUsesStepResampling() {
        let samples = (0...20).map {
            TindeqSample(milliseconds: Double($0) * 100, kilograms: $0 < 10 ? 10 : 20)
        }
        let result = ForceCurveEngine.meanMaxForce(samples: samples, windowSeconds: 1)
        XCTAssertNotNil(result)
        XCTAssertEqual(result ?? 0, 20, accuracy: 0.001)
    }

    func testCriticalForceFitRecoversKnownHyperbola() {
        let cf = 20.0
        let impulse = 100.0
        let recordings = [10.0, 20.0, 30.0, 60.0].map { duration -> [TindeqSample] in
            let force = cf + impulse / duration
            return stride(from: 0.0, through: duration * 1_000, by: 100).map {
                TindeqSample(milliseconds: $0, kilograms: force)
            }
        }
        let model = ForceCurveEngine.compute(recordings: recordings)
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.criticalForceKilograms ?? 0, cf, accuracy: 1.2)
        XCTAssertGreaterThan(model?.impulseAboveCriticalForceKilogramSeconds ?? 0, 0)
        XCTAssertLessThan(model?.impulseAboveCriticalForceKilogramSeconds ?? 0, impulse * 2)
        XCTAssertNotNil(model?.capabilityFit)
    }

    func testPercentageTargetRampsAndCapsAtOneHundredFiftyPercent() {
        let preset = TindeqPreset(
            name: "Ramp",
            holdSeconds: 10,
            repetitions: 1,
            sets: 4,
            restBetweenRepetitionsSeconds: 0,
            restBetweenSetsSeconds: 60,
            targetPercentage: 100,
            percentageBasis: .personalRecord,
            percentageStep: 20
        )
        let refs = ForceReferences(
            personalRecordKilograms: 50,
            criticalForceKilograms: 30,
            impulseAboveCriticalForceKilogramSeconds: 100,
            maximumForceKilograms: 50,
            capabilityFit: nil
        )
        XCTAssertEqual(ForceCurveEngine.targetKilograms(preset: preset, references: refs, setNumber: 1), 50)
        XCTAssertEqual(ForceCurveEngine.targetKilograms(preset: preset, references: refs, setNumber: 3), 70)
        XCTAssertEqual(ForceCurveEngine.targetKilograms(preset: preset, references: refs, setNumber: 4), 75)
    }

    func testReverseActionCompletionAndMetricsDoNotInventFutureMarkers() {
        let preset = TindeqPreset(
            name: "Movement",
            holdSeconds: 10,
            repetitions: 3,
            sets: 1,
            restBetweenRepetitionsSeconds: 0,
            restBetweenSetsSeconds: 0,
            protocolMode: .reverseAction,
            cadenceOutSeconds: 2,
            cadenceReturnSeconds: 2
        )
        let completion = ReverseActionEngine.completion(
            preset: preset,
            actualDurationMilliseconds: 9_000
        )
        XCTAssertEqual(completion.completedRepetitions, 2)
        XCTAssertEqual(completion.status, "partial")
        XCTAssertTrue(completion.markers.allSatisfy { $0.milliseconds <= 9_000 })

        let samples = stride(from: 0.0, through: 9_000, by: 1_000).map {
            TindeqSample(milliseconds: $0, kilograms: 10)
        }
        let band = ForceTargetBand(kilograms: 10, lowKilograms: 9, highKilograms: 11)
        let metrics = ReverseActionEngine.metrics(
            samples: samples,
            targetBand: band,
            plannedDurationMilliseconds: 12_000
        )
        XCTAssertEqual(metrics.meanKilograms ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(metrics.inTargetPercent ?? 0, 100, accuracy: 0.001)
        XCTAssertEqual(metrics.cadenceAdherencePercent, 75, accuracy: 0.001)
    }

    func testRoutineJSONCompatibilityRemainsSeparateFromForceMetadata() throws {
        let marker = CadenceMarker(milliseconds: 0, repetition: 1, direction: .out)
        let data = try JSONEncoder().encode(marker)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["milliseconds"] as? Int, 0)
        XCTAssertEqual(object?["repetition"] as? Int, 1)
    }
}
