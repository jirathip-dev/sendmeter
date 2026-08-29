import Foundation
import XCTest

final class SplashPresentationWiringTests: XCTestCase {
    func testSplashViewKeepsDynoAnimationAndReduceMotionPose() {
        let splash = source("Sources/App/SendmeterNativeApp.swift")
        XCTAssertTrue(splash.contains("@Environment(AppModel.self) private var model"))
        XCTAssertTrue(splash.contains("TimelineView(.animation)"))
        XCTAssertTrue(splash.contains("SplashDynoTimeline.pose("))
        XCTAssertTrue(splash.contains("at: context.date.timeIntervalSince(model.splashPresentationDate ?? context.date)\n                            )"))
        XCTAssertFalse(splash.contains("timeIntervalSinceReferenceDate"))
        XCTAssertTrue(splash.contains("if reduceMotion"))
        XCTAssertTrue(splash.contains("pose: .rest"))
        XCTAssertTrue(splash.contains("model.splashPresented(at: Date())"))
    }

    func testBootDismissalWaitsForTheColdStartFloor() {
        let appModel = source("Sources/App/AppModel.swift")
        XCTAssertTrue(appModel.contains("async let splashFloor: Void = awaitSplashPresentationFloor()"))
        XCTAssertTrue(appModel.contains("await splashFloor\n            bootState = .signedIn"))
        XCTAssertTrue(appModel.contains("await awaitSplashPresentationFloor()\n                bootState = .signedOut"))
        XCTAssertTrue(appModel.contains("func splashPresented(at date: Date)"))
        XCTAssertFalse(appModel.contains("SplashPresentationFloor(coldStartAt: Date())"))
    }

    private func source(_ relativePath: String) -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        do {
            return try String(
                contentsOf: packageRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
        } catch {
            XCTFail("Could not read source invariant: \(error)")
            return ""
        }
    }
}
