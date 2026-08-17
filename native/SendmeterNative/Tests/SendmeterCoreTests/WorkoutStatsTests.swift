import XCTest
@testable import SendmeterCore

final class WorkoutStatsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func sample(_ t: Double, _ hr: Double?) -> WorkoutHrSample {
        WorkoutHrSample(t: t, hr: hr)
    }

    /// A trace every 5 s: flat 160 until `endT`, then a linear fall to 120
    /// over 50 s — the web's recovery fixture shape.
    private func fallingTrace(endT: Double) -> [WorkoutHrSample] {
        var result: [WorkoutHrSample] = []
        var t = 0.0
        while t <= endT + 90 {
            let hr: Double?
            if t <= endT {
                hr = 160
            } else {
                hr = max(120, 160 - (t - endT))
            }
            result.append(sample(t, hr))
            t += 5
        }
        return result
    }

    func testAveragesHrAtEndMinusLowWithinWindow() {
        // Attempt ends at t=30 with HR 160; HR falls to 120 by t=80.
        let drop = WorkoutStats.hrRecoveryBpm(
            trace: fallingTrace(endT: 30),
            startedAt: start,
            attempts: [
                WorkoutAttempt(startedAt: start, durationSeconds: 30)
            ]
        )
        XCTAssertEqual(drop ?? -1, 40, accuracy: 0.01)
    }

    func testUsesTenSecondLookaheadForHrAtEnd() {
        // The first sample AT/after the attempt end with s.t <= t+10.
        // Attempt ends at t=30, samples exist at t=30 (160) and t=35 (155);
        // the grace window must pick t=30, not skip to a later one.
        let trace = fallingTrace(endT: 30)
        let drop = WorkoutStats.hrRecoveryBpm(
            trace: trace,
            startedAt: start,
            attempts: [
                WorkoutAttempt(startedAt: start, durationSeconds: 30)
            ]
        )
        XCTAssertEqual(drop ?? -1, 40, accuracy: 0.01)
    }

    func testReturnsNilWithNoUsableHr() {
        XCTAssertNil(WorkoutStats.hrRecoveryBpm(
            trace: [],
            startedAt: start,
            attempts: [
                WorkoutAttempt(startedAt: start, durationSeconds: 30)
            ]
        ))
    }

    func testNilWhenNoPositiveDrop() {
        // HR stays flat — no positive drop → nil (web parity: only positive
        // drops are averaged).
        let trace = [
            sample(0, 150), sample(5, 150), sample(10, 150),
            sample(15, 150), sample(20, 150), sample(25, 150),
            sample(30, 150), sample(35, 150), sample(40, 150)
        ]
        XCTAssertNil(WorkoutStats.hrRecoveryBpm(
            trace: trace,
            startedAt: start,
            attempts: [
                WorkoutAttempt(startedAt: start, durationSeconds: 30)
            ]
        ))
    }

    func testAveragesAcrossAttempts() {
        // Two attempts ending at t=30 and t=100, each with a 40 bpm drop.
        let attempts = [
            WorkoutAttempt(startedAt: start, durationSeconds: 30),
            WorkoutAttempt(startedAt: start.addingTimeInterval(100), durationSeconds: 30)
        ]
        let drop = WorkoutStats.hrRecoveryBpm(
            trace: fallingTrace(endT: 130),
            startedAt: start,
            attempts: attempts
        )
        XCTAssertEqual(drop ?? -1, 40, accuracy: 0.01)
    }

    func testIgnoresGapsInTheWindow() {
        // A sensor gap inside the 60 s window must not cap the low search —
        // nil samples are skipped, and a nil sample at the exact end is not
        // treated as a drop to 0.
        var trace = fallingTrace(endT: 30)
        // Null out samples 45–55 so the "low" is only reached later.
        trace = trace.map {
            ($0.t >= 45 && $0.t <= 55) ? sample($0.t, nil) : $0
        }
        let drop = WorkoutStats.hrRecoveryBpm(
            trace: trace,
            startedAt: start,
            attempts: [
                WorkoutAttempt(startedAt: start, durationSeconds: 30)
            ]
        )
        XCTAssertEqual(drop ?? -1, 40, accuracy: 0.01)
    }
}
