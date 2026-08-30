import XCTest

final class MenuActivationUITests: XCTestCase {
    func testMenuActivationPresentsAndTicksOnce() {
        let app = XCUIApplication()
        app.launchArguments = ["--menu-activation-probe"]
        app.launch()
        defer { app.terminate() }

        let trigger = app.buttons["change-block-menu"]
        XCTAssertTrue(trigger.waitForExistence(timeout: 10))
        trigger.tap()

        let menuItem = app.buttons["Strength"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "Menu presentation did not expose Strength")
        menuItem.tap()

        XCTAssertTrue(app.staticTexts["Menu ticks: 1"].waitForExistence(timeout: 5), "Menu activation did not emit exactly one haptic tick")
        XCTAssertFalse(app.staticTexts["Menu ticks: 2"].exists)
        XCTAssertTrue(app.staticTexts["Menu callbacks: 1"].exists)
        XCTAssertFalse(app.staticTexts["Menu callbacks: 2"].exists)
    }
}
