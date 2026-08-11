import SendLogWatchCore
import XCTest

final class FakeTindeqTests: XCTestCase {
    func testWaveformHasRampHoldReleaseAndRestPhases() {
        let waveform = FakeTindeqWaveform(
            configuration: FakeTindeqWaveformConfiguration(
                baselineKg: 0,
                peakKg: 20,
                rampMs: 100,
                holdMs: 200,
                releaseMs: 300,
                restMs: 100,
                sampleIntervalMs: 50,
                noiseKg: 0,
                seed: 7
            )
        )

        XCTAssertEqual(waveform.sample(at: 0).phase, .ramp)
        XCTAssertEqual(waveform.sample(at: 50).phase, .ramp)
        XCTAssertEqual(waveform.sample(at: 100).phase, .hold)
        XCTAssertEqual(waveform.sample(at: 299).phase, .hold)
        XCTAssertEqual(waveform.sample(at: 300).phase, .release)
        XCTAssertEqual(waveform.sample(at: 599).phase, .release)
        XCTAssertEqual(waveform.sample(at: 600).phase, .rest)
        XCTAssertEqual(waveform.sample(at: 699).phase, .rest)
        XCTAssertEqual(waveform.sample(at: 700).phase, .ramp)
    }

    func testNoiseIsDeterministicAndBounded() {
        let configuration = FakeTindeqWaveformConfiguration(
            baselineKg: 4,
            peakKg: 20,
            rampMs: 100,
            holdMs: 100,
            releaseMs: 100,
            restMs: 100,
            sampleIntervalMs: 10,
            noiseKg: 0.25,
            seed: 1234
        )
        let first = FakeTindeqWaveform(configuration: configuration)
            .samples(forDurationMs: 400)
        let second = FakeTindeqWaveform(configuration: configuration)
            .samples(forDurationMs: 400)

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains { abs($0.kg - 4) > 0 }, "the fake should include noise")
        for sample in first {
            let ideal = FakeTindeqWaveform(configuration: configuration)
                .sample(at: sample.elapsedMs)
            XCTAssertEqual(sample, ideal)
            XCTAssertGreaterThanOrEqual(sample.kg, 0)
        }
    }

    func testSamplesUseFixedStepsAndIncludeExactEnd() {
        let waveform = FakeTindeqWaveform(
            configuration: FakeTindeqWaveformConfiguration(
                rampMs: 100,
                holdMs: 100,
                releaseMs: 100,
                restMs: 100,
                sampleIntervalMs: 30,
                noiseKg: 0
            )
        )

        let samples = waveform.samples(forDurationMs: 95)
        XCTAssertEqual(samples.map(\.elapsedMs), [0, 30, 60, 90, 95])
        XCTAssertEqual(samples.last?.elapsedMs, 95)
    }

    func testMidRepScriptDisconnectsHalfwayThroughHold() {
        let script = FakeTindeqScript.midRepDisconnect
        let disconnectAt = script.disconnectAfterMs
        XCTAssertNotNil(disconnectAt)
        XCTAssertEqual(
            disconnectAt,
            script.waveform.holdStartMs + script.waveform.configuration.holdMs / 2
        )
        XCTAssertEqual(
            script.waveform.sample(at: disconnectAt!).phase,
            .hold
        )
    }

    func testDefaultPullExceedsHandsFreeWindows() {
        let waveform = FakeTindeqWaveform()
        let samples = waveform.samples(forDurationMs: waveform.cycleDurationMs)
        let firstAboveStart = samples.first { $0.kg >= HandsFreeForceConfig.default.startKg }
        let firstBelowStopAfterHold = samples.first {
            $0.elapsedMs > waveform.releaseStartMs && $0.kg <= HandsFreeForceConfig.default.stopKg
        }

        XCTAssertNotNil(firstAboveStart)
        XCTAssertNotNil(firstBelowStopAfterHold)
        XCTAssertGreaterThan(
            waveform.cycleDurationMs - (firstBelowStopAfterHold?.elapsedMs ?? 0),
            UInt32(HandsFreeForceConfig.default.stopGraceMs)
        )
    }
}
