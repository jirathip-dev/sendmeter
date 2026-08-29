import Foundation
import XCTest
@testable import SendmeterCore

final class SplashPresentationFloorTests: XCTestCase {
    func testColdStartWaitsUntilOneSecondHasElapsed() {
        let start = Date(timeIntervalSince1970: 100)
        let floor = SplashPresentationFloor(coldStartAt: start)

        XCTAssertEqual(SplashPresentationFloor.duration, 1.0)
        XCTAssertFalse(floor.isSatisfied(at: start.addingTimeInterval(0.999)))
        XCTAssertTrue(floor.isSatisfied(at: start.addingTimeInterval(1.0)))
        XCTAssertEqual(floor.remaining(at: start.addingTimeInterval(0.25)), 0.75, accuracy: 1e-9)
    }

    func testWarmResumeIsImmediate() {
        let floor = SplashPresentationFloor(coldStartAt: nil)

        XCTAssertTrue(floor.isSatisfied(at: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(floor.remaining(at: Date(timeIntervalSince1970: 0)), 0)
    }

    func testReduceMotionStillUsesColdStartFloor() {
        let start = Date(timeIntervalSince1970: 100)
        let floor = SplashPresentationFloor(coldStartAt: start)

        XCTAssertFalse(floor.isSatisfied(at: start.addingTimeInterval(0.5)))
        XCTAssertTrue(floor.isSatisfied(at: start.addingTimeInterval(1.0)))
    }
}
