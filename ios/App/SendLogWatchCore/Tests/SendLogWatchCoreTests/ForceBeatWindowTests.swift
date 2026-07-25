import XCTest
@testable import SendLogWatchCore

// MARK: - ForceBeatWindow (issue #148)

/// The old fixed-3s-trailing-window beat left a permanent gap in the phone
/// mirror's sparkline whenever WatchConnectivity reachability flapped for
/// longer than 3 s between successful beats. These cover the replacement's
/// backfill/cap/thinning behavior in isolation from WatchConnectivity.
final class ForceBeatWindowTests: XCTestCase {
    private func evenSamples(count: Int, stepMs: Double, kg: Double = 10) -> [(t: Double, kg: Double)] {
        (0..<count).map { (t: Double($0) * stepMs, kg: kg) }
    }

    func testNilSinceTSpansAtMostCapMsBackFromLastSample() {
        let samples = evenSamples(count: 21, stepMs: 1_000) // t = 0, 1000, ..., 20000
        let out = ForceBeatWindow.window(samples: samples, sinceT: nil, capMs: 15_000, maxPoints: 40)
        let bound = samples.last!.t - 15_000 // 5000
        XCTAssertTrue(out.allSatisfy { $0[0] > bound })
        XCTAssertEqual(out.first?[0], 6_000)
    }

    func testSinceTOnlyIncludesPointsAfterIt() {
        let samples = evenSamples(count: 11, stepMs: 500) // t = 0, 500, ..., 5000
        let out = ForceBeatWindow.window(samples: samples, sinceT: 4_000, capMs: 15_000, maxPoints: 40)
        XCTAssertEqual(out.map { $0[0] }, [4_500, 5_000])
    }

    /// The regression this fix targets: a gap wider than the old fixed 3 s
    /// window (but inside `capMs`) must be backfilled in full, not silently
    /// dropped.
    func testGapWiderThanOldFixedWindowIsBackfilled() {
        let samples = evenSamples(count: 121, stepMs: 100) // t = 0, 100, ..., 12000
        let out = ForceBeatWindow.window(samples: samples, sinceT: 0, capMs: 15_000, maxPoints: 40)
        XCTAssertLessThanOrEqual(out.count, 40)
        // A fixed 3s window would only reach back to t=9000; this must reach
        // much further back toward the sinceT watermark.
        XCTAssertLessThan(out.first?[0] ?? .infinity, 9_000)
    }

    func testSinceTOlderThanCapMsIsClampedAndThinned() {
        let samples = evenSamples(count: 101, stepMs: 10) // t = 0, 10, ..., 1000
        let out = ForceBeatWindow.window(samples: samples, sinceT: -1_000_000, capMs: 1_000, maxPoints: 10)
        XCTAssertEqual(out.count, 10)
        XCTAssertTrue(out.allSatisfy { $0[0] > 0 }) // clamped to last.t - capMs == 0
    }

    func testEmptySamplesReturnsEmpty() {
        XCTAssertEqual(ForceBeatWindow.window(samples: [], sinceT: nil), [])
    }

    func testSingleSampleDoesNotCrashOrDivideByZero() {
        let out = ForceBeatWindow.window(samples: [(t: 0, kg: 12.345)], sinceT: nil)
        XCTAssertEqual(out, [[0, 12.35]])
    }

    func testSinceTAtOrAfterLastSampleReturnsEmpty() {
        let samples = [(t: 0.0, kg: 1.0), (t: 1_000.0, kg: 2.0)]
        XCTAssertEqual(ForceBeatWindow.window(samples: samples, sinceT: 1_000), [])
        XCTAssertEqual(ForceBeatWindow.window(samples: samples, sinceT: 1_500), [])
    }

    func testRoundingParityWithSparkWindow() {
        let out = ForceBeatWindow.window(samples: [(t: 123.6, kg: 45.678)], sinceT: nil)
        XCTAssertEqual(out, [[124, 45.68]])
    }
}
