import XCTest

/// #926: the empty-workout End refusal must be explained AT the active
/// manual-workout presentation. The production path is driven end to end on a
/// simulator: the DEBUG `--manual-workout-fixture` harness arms the REAL
/// manual workout (same engine, same full-screen view, same End control, same
/// refusal presentation) because a signed-out simulator cannot sign in.
///
/// The assertions are the lane's discriminating ones: the explanation has to
/// be an element INSIDE the full-screen workout (its own identifier, not the
/// root banner, which renders behind the cover), it must survive a second End
/// tap, the refused action must not dismiss, and minimizing must not leak an
/// obsolete explanation onto the tab.
final class ManualWorkoutEndRefusalUITests: XCTestCase {
    /// The product copy the refusal must carry (FriendlyErrorClass
    /// `.missingAttempt`).
    private let refusalCopy = "Record at least one attempt before finishing the workout."

    func testEndOnAnEmptyWorkoutExplainsInsideTheFullScreen() {
        let app = launchArmedWorkout()
        defer { app.terminate() }

        let end = app.buttons["End manual workout"]
        XCTAssertTrue(
            end.waitForExistence(timeout: 60),
            "the manual workout full screen never appeared"
        )

        end.tap()

        let refusal = app.staticTexts["manual-workout-end-refusal"]
        XCTAssertTrue(
            refusal.waitForExistence(timeout: 10),
            "a refused End must explain itself inside the full-screen workout"
        )
        XCTAssertEqual(
            refusal.label,
            refusalCopy,
            "the explanation must be the friendly copy, in full"
        )
        XCTAssertTrue(
            refusal.isHittable,
            "the explanation must be readable on screen, not behind the modal"
        )
        XCTAssertGreaterThan(
            refusal.frame.height,
            0,
            "the explanation must occupy real layout"
        )
        XCTAssertTrue(
            end.exists,
            "a refused End must not dismiss the workout"
        )
        XCTAssertFalse(
            app.staticTexts["error-banner-message"].exists,
            "the explanation must not be delegated to the root banner, which the cover hides"
        )

        // End stays available to re-explain: the second tap presents a new
        // refusal rather than silently reusing the old one.
        end.tap()
        XCTAssertTrue(
            refusal.waitForExistence(timeout: 5),
            "a second End tap must still explain the refusal"
        )
        XCTAssertEqual(refusal.label, refusalCopy)
        XCTAssertFalse(
            app.staticTexts["error-banner-message"].exists,
            "nor on the second tap"
        )

        attachScreenshot(named: "manual-workout-end-refusal")
    }

    func testMinimizeAndResumeKeepTheWorkoutWithoutAnObsoleteRefusal() {
        let app = launchArmedWorkout()
        defer { app.terminate() }

        let end = app.buttons["End manual workout"]
        XCTAssertTrue(end.waitForExistence(timeout: 60), "the manual workout never appeared")
        end.tap()
        XCTAssertTrue(
            app.staticTexts["manual-workout-end-refusal"].waitForExistence(timeout: 10),
            "fixture: the refusal must be on screen before minimizing"
        )

        app.buttons["Minimize manual workout"].tap()

        XCTAssertTrue(
            end.waitForNonExistence(timeout: 10),
            "minimizing must leave the full-screen workout"
        )
        XCTAssertTrue(
            app.buttons["Open full screen"].waitForExistence(timeout: 10),
            "the workout must stay armed in the tab"
        )
        XCTAssertFalse(
            app.staticTexts["manual-workout-end-refusal"].exists,
            "the refusal belongs to the full screen that showed it"
        )
        XCTAssertFalse(
            app.staticTexts["error-banner-message"].exists,
            "minimizing must not leave an obsolete error on the tab"
        )

        app.buttons["Open full screen"].tap()

        XCTAssertTrue(end.waitForExistence(timeout: 10), "resuming must restore the full screen")
        XCTAssertFalse(
            app.staticTexts["manual-workout-end-refusal"].exists,
            "resuming must not re-present a refusal the user has already read"
        )
        attachScreenshot(named: "manual-workout-resumed")
    }

    func testCompletedAttemptEndsWithoutARefusal() {
        let app = launchArmedWorkout()
        defer { app.terminate() }

        let start = app.buttons["Start boulder"]
        XCTAssertTrue(
            start.waitForExistence(timeout: 60),
            "the manual workout full screen never appeared"
        )
        start.tap()

        let done = app.buttons["Done boulder"]
        XCTAssertTrue(
            done.waitForExistence(timeout: 10),
            "the running attempt must expose its completion control"
        )
        done.tap()

        let end = app.buttons["End manual workout"]
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        end.tap()

        XCTAssertTrue(
            end.waitForNonExistence(timeout: 15),
            "a completed workout's End must exit the full screen instead of refusing"
        )
        XCTAssertFalse(
            app.staticTexts["manual-workout-end-refusal"].exists,
            "a completed attempt must not be refused"
        )
        XCTAssertTrue(
            app.buttons["Start Manual workout"].waitForExistence(timeout: 10),
            "the finished workout must leave the tab ready for a new one"
        )
        attachScreenshot(named: "manual-workout-finished")
    }

    // MARK: - Harness

    private func launchArmedWorkout() -> XCUIApplication {
        var app = makeArmedApp()
        app.launch()
        guard !app.buttons["Start boulder"].waitForExistence(timeout: 25) else { return app }

        // Harness guard, not a product retry: the launch-argument fixture
        // occasionally fails to attach on this host (measured once in four
        // runs — that launch rendered the signed-out LoginView because the
        // fixture route was not taken; its UI-hierarchy attachment is part of
        // the lane's evidence). Relaunch once; if the workout still does not
        // arm, the caller's own assertion reports the missing full screen.
        print("impl-926 harness: --manual-workout-fixture did not arm on the first launch; relaunching once")
        app.terminate()
        app = makeArmedApp()
        app.launch()
        return app
    }

    private func makeArmedApp() -> XCUIApplication {
        let app = XCUIApplication()
        // The tabs fixture renders the real tab bar without a session; the
        // manual-workout fixture arms the real workout inside the Workout tab.
        app.launchArguments = ["--tabs-fixture", "workout", "--manual-workout-fixture"]
        return app
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
