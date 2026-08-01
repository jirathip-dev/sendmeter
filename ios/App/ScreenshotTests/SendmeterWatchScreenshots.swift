import XCTest

@MainActor
final class SendmeterWatchScreenshots: XCTestCase {
    func testAppStoreScreenshots() throws {
        let app = XCUIApplication()
        setupSnapshot(app, waitForAnimations: true)
        app.launch()

        XCTAssertTrue(app.staticTexts["READINESS"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["82"].exists)
        snapshot("01-watch-status")

        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["Force Gauge"].waitForExistence(timeout: 10))
        snapshot("02-watch-actions")
    }
}
