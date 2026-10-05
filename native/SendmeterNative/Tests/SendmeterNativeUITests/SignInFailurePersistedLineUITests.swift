import XCTest

/// #992 runtime leg: a REAL sign-in failure driven through the real UI — no
/// test seam, no sink substitution — surfaces the app's own error banner, and
/// the same failure is the one the `.notice` line records (`launch failure
/// step=banner domain=… code=… class=… surfaced=true`, category
/// `launch-failure`). The app-target suite (`PersistedFailureLogAppTests`)
/// proves the emitted FIELDS at the sink; the simulator's unified log is the
/// half only a real launch of the plain app can prove.
///
/// Not wired into any workflow; run by hand:
///   xcodebuild test … -only-testing:SendmeterNativeUITests/SignInFailurePersistedLineUITests
/// then read the simulator log with persisted levels only (no --info/--debug).
final class SignInFailurePersistedLineUITests: XCTestCase {
    func testFailedSignInShowsTheErrorBanner() {
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }

        let email = app.textFields["Email"]
        XCTAssertTrue(
            email.waitForExistence(timeout: 30),
            "the sign-in form never appeared"
        )
        email.tap()
        email.typeText("992-probe@invalid.example")

        let password = app.secureTextFields["Password"]
        password.tap()
        password.typeText("wrong-password-992")

        // Dismiss any soft keyboard before tapping the submit control, or the
        // hit test lands on the keyboard.
        app.staticTexts["Sendmeter"].firstMatch.tap()

        // The segmented control's own option is ALSO labelled "Sign In"; the
        // submit control is the one below the password field.
        let submit = app.buttons
            .matching(NSPredicate(format: "label == %@", "Sign In"))
            .allElementsBoundByIndex
            .first { $0.frame.minY > password.frame.maxY }
        XCTAssertNotNil(submit, "the Sign In submit control was not found")
        submit?.tap()

        // The production backend rejects the credentials; the REAL banner is
        // the user-visible surface (and the persisted line is its trace).
        let dismiss = app.buttons["error-banner-dismiss"]
        XCTAssertTrue(
            dismiss.waitForExistence(timeout: 60),
            "the error banner never appeared after the failed sign-in"
        )
        XCTAssertEqual(dismiss.label, "Dismiss error")
    }
}
