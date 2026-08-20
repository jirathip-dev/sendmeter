import XCTest
@testable import SendmeterCore

private struct ForceCurveBootstrapFixture: Decodable {
    let seed: UInt32
    let bootstrapSamples: Int
    let lowSampleIndices: [Int]
    let comparisonWindowIndex: Int
    let recordings: [[[Double]]]
    let expected: Expected

    struct Expected: Decodable {
        let points: [[Double]]
        let criticalForceKilograms: Double
        let impulseAboveCriticalForceKilogramSeconds: Double
        let capabilityFit: [Double]
        let band: [[Double]]
        let lowBand: [[Double]]
    }
}

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

    func testBootstrapMatchesWebFixture() throws {
        // KEEP-IN-SYNC with src/lib/force-curve.test.ts: both tests decode
        // this exact JSON fixture and compare the web-produced expected band.
        let fixture = try loadBootstrapFixture()
        XCTAssertEqual(fixture.seed, 0x0352c0de)

        let model = try XCTUnwrap(
            ForceCurveEngine.compute(
                recordings: fixture.recordings.map(samples(from:)),
                bootstrapSamples: fixture.bootstrapSamples,
                seed: fixture.seed
            )
        )

        XCTAssertEqual(model.points.count, fixture.expected.points.count)
        for (index, expected) in fixture.expected.points.enumerated() {
            XCTAssertEqual(model.points[index].windowSeconds, expected[0], accuracy: 1e-10)
            XCTAssertEqual(model.points[index].kilograms, expected[1], accuracy: 1e-10)
        }
        XCTAssertEqual(model.criticalForceKilograms ?? 0, fixture.expected.criticalForceKilograms, accuracy: 1e-9)
        XCTAssertEqual(
            model.impulseAboveCriticalForceKilogramSeconds ?? 0,
            fixture.expected.impulseAboveCriticalForceKilogramSeconds,
            accuracy: 1e-9
        )

        let fit = try XCTUnwrap(model.capabilityFit)
        XCTAssertEqual(fit.exponent, fixture.expected.capabilityFit[0], accuracy: 1e-10)
        XCTAssertEqual(fit.tau, fixture.expected.capabilityFit[1], accuracy: 1e-9)
        XCTAssertEqual(fit.sumSquaredError, fixture.expected.capabilityFit[2], accuracy: 1e-9)

        let band = try XCTUnwrap(model.confidenceBand)
        XCTAssertEqual(band.count, 65)
        for expected in fixture.expected.band {
            let index = Int(expected[0])
            XCTAssertEqual(band[index].windowSeconds, expected[1], accuracy: 1e-10)
            XCTAssertEqual(band[index].kilograms, expected[2], accuracy: 1e-9)
            XCTAssertEqual(band[index].lowKilograms, expected[3], accuracy: 1e-9)
            XCTAssertEqual(band[index].highKilograms, expected[4], accuracy: 1e-9)
        }
    }

    func testLowSampleFixtureProducesAWiderTailBand() throws {
        let fixture = try loadBootstrapFixture()
        let recordings = fixture.recordings.map(samples(from:))
        let full = try XCTUnwrap(
            ForceCurveEngine.compute(
                recordings: recordings,
                bootstrapSamples: fixture.bootstrapSamples,
                seed: fixture.seed
            )
        )
        let low = try XCTUnwrap(
            ForceCurveEngine.compute(
                recordings: fixture.lowSampleIndices.map { recordings[$0] },
                bootstrapSamples: fixture.bootstrapSamples,
                seed: fixture.seed
            )
        )
        let fullBand = try XCTUnwrap(full.confidenceBand)
        let lowBand = try XCTUnwrap(low.confidenceBand)
        let index = fixture.comparisonWindowIndex
        let fullWidth = fullBand[index].highKilograms - fullBand[index].lowKilograms
        let lowWidth = lowBand[index].highKilograms - lowBand[index].lowKilograms
        XCTAssertGreaterThan(lowWidth, fullWidth)

        for expected in fixture.expected.lowBand {
            let bandIndex = Int(expected[0])
            XCTAssertEqual(lowBand[bandIndex].windowSeconds, expected[1], accuracy: 1e-10)
            XCTAssertEqual(lowBand[bandIndex].kilograms, expected[2], accuracy: 1e-9)
            XCTAssertEqual(lowBand[bandIndex].lowKilograms, expected[3], accuracy: 1e-9)
            XCTAssertEqual(lowBand[bandIndex].highKilograms, expected[4], accuracy: 1e-9)
        }
    }

    func testBootstrapIsDeterministicForTheSameSeed() throws {
        let fixture = try loadBootstrapFixture()
        let recordings = fixture.recordings.map(samples(from:))
        let first = ForceCurveEngine.compute(
            recordings: recordings,
            bootstrapSamples: fixture.bootstrapSamples,
            seed: fixture.seed
        )
        let second = ForceCurveEngine.compute(
            recordings: recordings,
            bootstrapSamples: fixture.bootstrapSamples,
            seed: fixture.seed
        )
        XCTAssertEqual(first, second)
    }

    private func loadBootstrapFixture() throws -> ForceCurveBootstrapFixture {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "force-curve-bootstrap",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        return try JSONDecoder().decode(ForceCurveBootstrapFixture.self, from: Data(contentsOf: url))
    }

    private func samples(from recording: [[Double]]) -> [TindeqSample] {
        recording.map { pair in
            TindeqSample(milliseconds: pair[0], kilograms: pair[1])
        }
    }
}
