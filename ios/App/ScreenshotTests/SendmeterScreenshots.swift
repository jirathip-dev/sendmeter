import XCTest

@MainActor
final class SendmeterScreenshots: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        setupSnapshot(app, waitForAnimations: true)
        app.launch()
    }

    func testAppStoreScreenshots() throws {
        signInToLocalFixture()
        dismissPasskeyPromptIfNeeded()

        let readiness = app.staticTexts["Readiness"]
        XCTAssertTrue(readiness.waitForExistence(timeout: 20))
        snapshot("01-home-readiness")

        app.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["HISTORY"].waitForExistence(timeout: 10))
        snapshot("02-history")

        app.buttons["Force"].tap()
        XCTAssertTrue(app.buttons["Connect Progressor"].waitForExistence(timeout: 20))
        snapshot("03-force-overview")

        let curveInfo = app.buttons["About: How the Force Curve works"]
        let webView = app.webViews.firstMatch
        for _ in 0..<14 where !curveInfo.isHittable {
            webView.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(curveInfo.isHittable, "The populated force curve should be visible")

        let upperHalf = app.windows.firstMatch.frame.height * 0.45
        for _ in 0..<4 where curveInfo.frame.midY > upperHalf {
            webView.swipeUp(velocity: .fast)
        }
        XCTAssertLessThanOrEqual(
            curveInfo.frame.midY,
            upperHalf,
            "The force curve should be framed in the upper half of the screenshot"
        )
        snapshot("04-force-curve")
    }

    private func signInToLocalFixture() {
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 15))
        email.tap()
        email.typeText("dev@sendmeter.test")

        let password = app.secureTextFields["Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        password.tap()
        password.typeText("devpassword")

        app.buttons["Sign In"].tap()
    }

    private func dismissPasskeyPromptIfNeeded() {
        let notNow = app.buttons["Not now"]
        if notNow.waitForExistence(timeout: 4) {
            notNow.tap()
        }
    }
}
