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

        // The iPad's two-column desktop layout reaches its natural scroll
        // boundary with the curve just below center; phones can frame it
        // higher. Both limits keep the complete chart in the capture.
        let deviceName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        let curveFrameLimit = app.windows.firstMatch.frame.height * (deviceName.hasPrefix("iPad") ? 0.60 : 0.45)
        for _ in 0..<4 where curveInfo.frame.midY > curveFrameLimit {
            webView.swipeUp(velocity: .fast)
        }
        XCTAssertLessThanOrEqual(
            curveInfo.frame.midY,
            curveFrameLimit,
            "The force curve should be framed prominently in the screenshot"
        )
        snapshot("04-force-curve")
    }

    private func signInToLocalFixture() {
        let email = app.textFields["Email"]
        // Snapshot retries do not always reinstall the app. If the first run
        // signed in before a later assertion failed, reuse that valid session.
        // A freshly erased 13-inch iPad can also take longer to finish its
        // first WebView launch, so allow a generous cold-start window.
        if !email.waitForExistence(timeout: 30) {
            XCTAssertTrue(
                app.staticTexts["Readiness"].waitForExistence(timeout: 20),
                "Expected either the local-fixture sign-in form or an existing signed-in session"
            )
            return
        }
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
