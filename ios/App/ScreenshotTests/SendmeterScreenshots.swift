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
        // The redesigned Force flow starts with exercise + protocol setup and
        // only presents the Progressor connection action once those inputs are
        // ready. Anchor the overview capture to the stable screen heading so
        // copy and connection-state changes cannot break App Store generation.
        XCTAssertTrue(app.staticTexts["FORCE"].waitForExistence(timeout: 20))
        snapshot("03-force-overview")

        let webView = app.webViews.firstMatch
        // WKWebView exposes the card's composed visible label on some iOS
        // runtimes instead of its aria-label. Match the stable product term
        // across either representation.
        let staticInsights = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Static capacity"))
            .firstMatch
        for _ in 0..<14 where !staticInsights.isHittable {
            webView.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(staticInsights.isHittable, "The Static capacity card should be visible")
        staticInsights.tap()

        XCTAssertTrue(
            app.buttons["Close Static capacity"].waitForExistence(timeout: 10),
            "The Static capacity bottom sheet should open"
        )
        let curveInfo = app.buttons["About: How the Force Curve works"]
        for _ in 0..<14 where !curveInfo.isHittable {
            // With the sheet open, its full-height body owns this gesture and
            // the page beneath remains locked.
            webView.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(curveInfo.isHittable, "The populated force curve should be visible")

        // The sticky sheet header intentionally consumes more vertical room
        // than the old page-level chart. Keep the curve near center on phones
        // and allow the iPad's two-column layout to settle just below it;
        // both limits retain the complete chart and the persistent close UI.
        let deviceName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        let curveFrameLimit = app.windows.firstMatch.frame.height * (deviceName.hasPrefix("iPad") ? 0.60 : 0.55)
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
