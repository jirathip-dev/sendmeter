import XCTest
@testable import SendmeterCore

final class ForceMotionPolicyTests: XCTestCase {
    func testPhaseMotionTargetsTheBriefDuration() {
        XCTAssertEqual(ForceMotionPolicy.phaseResponseSeconds, 0.3, accuracy: 0.000_001)
        XCTAssertEqual(ForceMotionPolicy.phaseDampingFraction, 0.82, accuracy: 0.000_001)
        XCTAssertEqual(
            ForceMotionPolicy.phaseTransitionDuration(reduceMotion: false),
            0.3,
            accuracy: 0.000_001
        )
    }

    func testReduceMotionRemovesPhaseMotion() {
        XCTAssertEqual(ForceMotionPolicy.phaseTransitionDuration(reduceMotion: true), 0)
    }

    func testHeroPulseScalesOnlyForAnActivePress() {
        XCTAssertEqual(
            ForceMotionPolicy.heroScale(isPressed: true, reduceMotion: false),
            1.05,
            accuracy: 0.000_001
        )
        XCTAssertEqual(ForceMotionPolicy.heroScale(isPressed: false, reduceMotion: false), 1)
    }

    func testReduceMotionPreservesHeroStateButRemovesScaleMotion() {
        XCTAssertEqual(ForceMotionPolicy.heroScale(isPressed: true, reduceMotion: true), 1)
        XCTAssertEqual(ForceMotionPolicy.heroScale(isPressed: false, reduceMotion: true), 1)
    }
}
