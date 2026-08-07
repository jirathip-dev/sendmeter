import XCTest
import SendLogWatchCore

final class RPEModelTests: XCTestCase {
    /// Deterministic pseudo-random source (no Date/random dependency issues).
    private func synthRows(count: Int) -> [LabeledWorkout] {
        var rows: [LabeledWorkout] = []
        var seed = 42.0
        func next() -> Double {
            seed = (seed * 9301 + 49297).truncatingRemainder(dividingBy: 233280)
            return seed / 233280
        }
        // True generating process: rpe = 1 + 4·hrr + 0.5·effort + 0.2·density + noise
        for _ in 0..<count {
            let hrr = next()
            let effort = next() * 10
            let density = next() * 4
            let noise = (next() - 0.5) * 0.4
            let rpe = max(1, min(10, 1 + 4 * hrr + 0.5 * effort + 0.2 * density + noise))
            rows.append(LabeledWorkout(sessionHRR: hrr, meanEffort: effort, attemptsPer10min: density, rpe: rpe))
        }
        return rows
    }

    func testFitRecoversGeneratingProcess() {
        let rows = synthRows(count: 50)
        guard let model = RPEModelFitter.fit(rows: rows, lambda: 1.0, minSamples: 10) else {
            return XCTFail("fit returned nil")
        }
        XCTAssertEqual(model.sampleCount, 50)
        // Predictions should track the true process within noise tolerance
        var maxErr = 0.0
        for r in rows {
            let p = model.predict(sessionHRR: r.sessionHRR, meanEffort: r.meanEffort, attemptsPer10min: r.attemptsPer10min)
            maxErr = max(maxErr, abs(p - r.rpe))
        }
        XCTAssertLessThan(maxErr, 1.0, "ridge fit should be within noise band of the labels")
    }

    func testTooFewSamplesReturnsNil() {
        let rows = synthRows(count: 9)
        XCTAssertNil(RPEModelFitter.fit(rows: rows, lambda: 1.0, minSamples: 10))
    }

    func testConstantFeatureGetsNearZeroWeight() {
        var rows = synthRows(count: 40)
        rows = rows.map {
            LabeledWorkout(sessionHRR: $0.sessionHRR, meanEffort: $0.meanEffort, attemptsPer10min: 2.5, rpe: $0.rpe)
        }
        guard let model = RPEModelFitter.fit(rows: rows, lambda: 1.0, minSamples: 10) else {
            return XCTFail("fit returned nil")
        }
        XCTAssertLessThan(abs(model.weights[2]), 0.01, "constant feature should carry ~no weight")
    }

    func testIdenticalRowsDegenerate() {
        let row = LabeledWorkout(sessionHRR: 0.5, meanEffort: 5, attemptsPer10min: 2, rpe: 6)
        let rows = [LabeledWorkout](repeating: row, count: 20)
        // All features constant → standardized columns all zero → ridge still
        // solvable (bias absorbs the label); prediction must be the label.
        if let model = RPEModelFitter.fit(rows: rows, lambda: 1.0, minSamples: 10) {
            let p = model.predict(sessionHRR: 0.5, meanEffort: 5, attemptsPer10min: 2)
            XCTAssertEqual(p, 6, accuracy: 0.01)
        }
        // nil is also acceptable behavior for degenerate data — no assert
    }

    func testPredictionClamps() {
        let rows = synthRows(count: 30)
        guard let model = RPEModelFitter.fit(rows: rows, lambda: 1.0, minSamples: 10) else {
            return XCTFail("fit returned nil")
        }
        let hi = model.predict(sessionHRR: 5, meanEffort: 100, attemptsPer10min: 50)
        let lo = model.predict(sessionHRR: -5, meanEffort: -100, attemptsPer10min: -50)
        XCTAssertLessThanOrEqual(hi, 10)
        XCTAssertGreaterThanOrEqual(lo, 1)
    }

    func testSolve4x4Identity() {
        let identity: [[Double]] = [
            [1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1],
        ]
        let w = RPEModelFitter.solve4x4(identity, [1, 2, 3, 4])
        XCTAssertEqual(w?[0] ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(w?[3] ?? 0, 4, accuracy: 1e-9)
    }

    func testSolve4x4SingularReturnsNil() {
        let singular: [[Double]] = [
            [1, 2, 3, 4], [2, 4, 6, 8], [1, 1, 1, 1], [0, 0, 0, 1],
        ]
        XCTAssertNil(RPEModelFitter.solve4x4(singular, [1, 2, 3, 4]))
    }

    // MARK: - RPEQuantization (#107: auto-tracked RPE keeps 0.1 precision,
    // not the 0.5 half-point granularity used by the MANUAL steppers).

    func testAutoTrackedKeepsOneDecimalPrecision() {
        XCTAssertEqual(RPEQuantization.autoTracked(5.7), 5.7, accuracy: 1e-9)
        XCTAssertEqual(RPEQuantization.autoTracked(6.34), 6.3, accuracy: 1e-9)
        XCTAssertEqual(RPEQuantization.autoTracked(6.35), 6.4, accuracy: 1e-9)
        XCTAssertEqual(RPEQuantization.autoTracked(1.0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(RPEQuantization.autoTracked(10.0), 10.0, accuracy: 1e-9)
    }

    func testAutoTrackedDoesNotSnapToHalfPoints() {
        // The bug (#107): the old path rounded 5.7 down to 5.5. Assert it no
        // longer lands on a half-point step when the raw prediction doesn't.
        let p = RPEQuantization.autoTracked(5.7)
        XCTAssertEqual(p, 5.7, accuracy: 1e-9)
        XCTAssertGreaterThan(abs(p - 5.5), 0.01)
    }

    func testAutoTrackedClampsToValidRange() {
        XCTAssertEqual(RPEQuantization.autoTracked(-3.2), 1.0, accuracy: 1e-9)
        XCTAssertEqual(RPEQuantization.autoTracked(0.4), 1.0, accuracy: 1e-9)
        XCTAssertEqual(RPEQuantization.autoTracked(14.9), 10.0, accuracy: 1e-9)
    }

    func testAutoTrackedHandlesNaN() {
        XCTAssertEqual(RPEQuantization.autoTracked(.nan), 1.0, accuracy: 1e-9)
    }

    // MARK: - RPEModelStore (#473/#478: version bump clears the pre-fix model)

    private static let legacyKey = "rpeModel.v1"
    private static let currentKey = "rpeModel.v2"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.legacyKey)
        UserDefaults.standard.removeObject(forKey: Self.currentKey)
        super.tearDown()
    }

    func testStoreRoundTripsUnderTheCurrentKey() {
        guard let model = RPEModelFitter.fit(rows: synthRows(count: 20), lambda: 1.0, minSamples: 10) else {
            return XCTFail("fit returned nil")
        }
        RPEModelStore.save(model)
        XCTAssertNotNil(UserDefaults.standard.data(forKey: Self.currentKey), "save() must write under the current (v2) key")
        let loaded = RPEModelStore.load()
        XCTAssertEqual(loaded?.sampleCount, 20)
    }

    /// #473/#478: a model fitted by a pre-fix build sits under the OLD key
    /// ("rpeModel.v1") — it trained on this issue's corrupt features (a 27s
    /// boulder recorded as 1034s, 5 boulders recorded as 1). The version
    /// bump must make `load()` blind to it, so `refitRPEModelIfStale` (which
    /// treats `load() == nil` as unconditionally stale) refits from scratch
    /// on the next workout start rather than keep predicting from it.
    func testStoreIsBlindToALegacyV1Model() {
        guard let legacy = RPEModelFitter.fit(rows: synthRows(count: 20), lambda: 1.0, minSamples: 10) else {
            return XCTFail("fit returned nil")
        }
        let data = try! JSONEncoder().encode(legacy)
        UserDefaults.standard.set(data, forKey: Self.legacyKey)
        XCTAssertNil(RPEModelStore.load(), "a model written under the pre-#473 key must not be read back")
    }
}
