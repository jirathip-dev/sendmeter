import XCTest
@testable import SendmeterCore

/// Pins the splash kangaroo dyno to the web `@keyframes splash-dyno`
/// (src/index.css) so CSS drift on either side is caught by a diff instead of
/// a silently divergent animation: same stops, same cycle, same easing.
final class SplashDynoTimelineTests: XCTestCase {
    private let cycle = SplashDynoTimeline.cycleDuration

    private func pose(atPercent percent: Double) -> SplashDynoPose {
        SplashDynoTimeline.pose(at: percent / 100 * cycle)
    }

    private func assertPose(
        _ actual: SplashDynoPose,
        _ tx: Double, _ ty: Double, _ rotation: Double, _ sx: Double, _ sy: Double,
        _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let accuracy = 1e-9
        XCTAssertEqual(actual.txFraction, tx, accuracy: accuracy, "tx — \(message)", file: file, line: line)
        XCTAssertEqual(actual.tyFraction, ty, accuracy: accuracy, "ty — \(message)", file: file, line: line)
        XCTAssertEqual(actual.rotationDegrees, rotation, accuracy: accuracy, "rotation — \(message)", file: file, line: line)
        XCTAssertEqual(actual.scaleX, sx, accuracy: accuracy, "scaleX — \(message)", file: file, line: line)
        XCTAssertEqual(actual.scaleY, sy, accuracy: accuracy, "scaleY — \(message)", file: file, line: line)
    }

    // MARK: - Cycle

    func testCycleDurationIsFourPointTwoSeconds() {
        XCTAssertEqual(cycle, 4.2, accuracy: 1e-12, "must match `splash-dyno 4.2s`")
    }

    // MARK: - Keyframe stops (every stop of @keyframes splash-dyno)

    func testKeyframeStopsMatchCSS() {
        assertPose(pose(atPercent: 0), 0, 0, 0, 1, 1, "0% rest")
        assertPose(pose(atPercent: 4), 0, 0, 0, 1, 1, "4% still")
        assertPose(pose(atPercent: 5), -0.01, 0.02, -1, 1.035, 0.965, "5% crouch")
        assertPose(pose(atPercent: 11), 0.05, -0.08, 4, 0.98, 1.02, "11% rise")
        assertPose(pose(atPercent: 15), 0.06, -0.10, 6, 1, 1, "15% apex")
        assertPose(pose(atPercent: 18), 0.04, 0.03, 44, 1, 1, "18% tip over")
        assertPose(pose(atPercent: 20), 0, 0.24, 88, 1.04, 0.96, "20% land back-first")
        assertPose(pose(atPercent: 22), 0, 0.20, 94, 0.99, 1.01, "22% squash")
        assertPose(pose(atPercent: 23.5), 0, 0.23, 90, 1, 1, "23.5% settle on pad")
        assertPose(pose(atPercent: 64), 0, 0.23, 90, 1, 1, "64% hold end")
        assertPose(pose(atPercent: 76), -0.03, 0.14, 45, 1, 1, "76% recover")
        assertPose(pose(atPercent: 86), 0, 0, 0, 1, 1, "86% upright again")
        assertPose(pose(atPercent: 100), 0, 0, 0, 1, 1, "100% rest")
    }

    /// The hold is one compound keyframe (23.5%, 64%) — every sample between
    /// the two must be the back-flipped pose, no drift.
    func testHoldPhaseIsConstantBackFirst() {
        for percent in stride(from: 24.0, through: 64.0, by: 4.0) {
            assertPose(pose(atPercent: percent), 0, 0.23, 90, 1, 1, "hold at \(percent)%")
        }
    }

    // MARK: - Easing

    func testEaseSegmentProgressPinsCubicBezier() {
        // Independent reference: cubic-bezier(0.35, 0, 0.2, 1) solved for
        // bezierX(t) == x (bisection, 60 iterations) with y1=0, y2=1.
        XCTAssertEqual(SplashDynoTimeline.easeSegmentProgress(0.25), 0.29225123469010644, accuracy: 1e-6)
        XCTAssertEqual(SplashDynoTimeline.easeSegmentProgress(0.5), 0.7870694383028509, accuracy: 1e-6)
        XCTAssertEqual(SplashDynoTimeline.easeSegmentProgress(0.75), 0.9600653513309325, accuracy: 1e-6)
    }

    func testEaseSegmentProgressEndpointsAndMonotonicity() {
        XCTAssertEqual(SplashDynoTimeline.easeSegmentProgress(0), 0, accuracy: 1e-12)
        XCTAssertEqual(SplashDynoTimeline.easeSegmentProgress(1), 1, accuracy: 1e-12)
        let quarter = SplashDynoTimeline.easeSegmentProgress(0.25)
        let mid = SplashDynoTimeline.easeSegmentProgress(0.5)
        let threeQuarter = SplashDynoTimeline.easeSegmentProgress(0.75)
        XCTAssertLessThanOrEqual(quarter, mid, "easing must be monotonic")
        XCTAssertLessThanOrEqual(mid, threeQuarter, "easing must be monotonic")
    }

    /// Crouch 4%→5% is a 42ms segment; easing is applied *within* it, so the
    /// midpoint value must be eased from 0 to 1, not at the linear 50% pose:
    /// tx = 0 + (-0.01) * ease(0.5).
    func testSegmentMidpointUsesEasedProgress() {
        let midpoint = pose(atPercent: 4.5)
        let eased = SplashDynoTimeline.easeSegmentProgress(0.5) // 0.7870694383028509
        let expectedTx = -0.01 * eased
        XCTAssertEqual(midpoint.txFraction, expectedTx, accuracy: 1e-9)
        XCTAssertEqual(midpoint.rotationDegrees, -1 * eased, accuracy: 1e-9)

        // 64%→76% recover, midpoint at 70%: ty = 0.23 + (0.14 - 0.23) * ease(0.5).
        let recover = pose(atPercent: 70)
        XCTAssertEqual(recover.tyFraction, 0.23 + (0.14 - 0.23) * eased, accuracy: 1e-9)
        XCTAssertEqual(recover.rotationDegrees, 90 + (45 - 90) * eased, accuracy: 1e-9)
    }

    // MARK: - Looping

    func testPoseIsPeriodicOverTheCycle() {
        let samples: [Double] = [0, 0.5, 1.0, 1.7, 2.3, 3.0, 3.9, 4.199]
        for t in samples {
            XCTAssertEqual(
                SplashDynoTimeline.pose(at: t),
                SplashDynoTimeline.pose(at: t + cycle),
                "pose at \(t) must equal pose at \(t) + one cycle"
            )
        }
        // The zero/cycle boundary is continuous: 4.2s ≡ 0s.
        XCTAssertEqual(SplashDynoTimeline.pose(at: cycle), SplashDynoTimeline.pose(at: 0))
    }

    func testNegativeElapsedTimeWrapsIntoTheCycle() {
        XCTAssertEqual(
            SplashDynoTimeline.pose(at: -0.2),
            SplashDynoTimeline.pose(at: cycle - 0.2)
        )
    }

    // MARK: - Reduce-motion fallback contract

    /// Web reduce-motion kills the CSS animation (`animation: none`), leaving
    /// the element at its base transform — the rest pose.
    func testRestPoseIsIdentity() {
        let rest = SplashDynoPose.rest
        XCTAssertEqual(rest, SplashDynoPose(txFraction: 0, tyFraction: 0, rotationDegrees: 0, scaleX: 1, scaleY: 1))
    }
}
