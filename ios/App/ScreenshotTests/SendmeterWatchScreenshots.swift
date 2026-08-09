import XCTest

@MainActor
final class SendmeterWatchScreenshots: XCTestCase {
    /// Keep the fixture matrix exercised without adding extra App Store
    /// screenshots. Every state still launches the production hierarchy and
    /// checks the semantic state affordance that the design system promises;
    /// the two named snapshots below remain the curated store deliverables.
    func testDeterministicFixtureMatrix() throws {
        let homeStates: [(fixture: String, identifier: String)] = [
            ("status", "watch-state-ready"),
            ("statusEmpty", "watch-state-warning"),
            ("statusSyncing", "watch-state-syncing"),
            ("statusOffline", "watch-state-offline"),
            ("statusCached", "watch-state-cached"),
            ("waiting", "watch-state-syncing"),
        ]

        for item in homeStates {
            let app = launchFixture(item.fixture)
            XCTAssertTrue(
                app.descendants(matching: .any)
                    .matching(identifier: item.identifier)
                    .firstMatch
                    .waitForExistence(timeout: 10),
                "fixture \(item.fixture) should expose \(item.identifier)"
            )
            if item.fixture == "status" {
                XCTAssertEqual(app.pageIndicators.count, 0, "explicit page selector must replace native dots")
                let statusPage = app.buttons["Show Status"]
                let actionsPage = app.buttons["Show Actions"]
                XCTAssertTrue(statusPage.waitForExistence(timeout: 5))
                XCTAssertTrue(actionsPage.waitForExistence(timeout: 5))
                assertFullyVisible(statusPage, in: app, fixture: item.fixture)
                assertFullyVisible(actionsPage, in: app, fixture: item.fixture)
                actionsPage.tap()
                XCTAssertTrue(app.staticTexts["Force Gauge"].waitForExistence(timeout: 5))
                statusPage.tap()
            }
            app.terminate()
        }

        let actionStates: [(fixture: String, identifier: String)] = [
            ("actions", "Force Gauge"),
            ("actionsOffline", "watch-banner-offline"),
            ("actionsSyncing", "watch-banner-syncing"),
        ]
        for item in actionStates {
            let app = launchFixture(item.fixture)
            openActions(app)
            XCTAssertTrue(
                app.descendants(matching: .any)
                    .matching(identifier: item.identifier).firstMatch
                    .waitForExistence(timeout: 10),
                "fixture \(item.fixture) should expose \(item.identifier)"
            )
            app.terminate()
        }

        let workoutStates: [(fixture: String, identifier: String)] = [
            ("workoutIdle", "Start Workout"),
            ("workoutLive", "End"),
            ("workoutRest", "End"),
            ("workoutSaved", "watch-state-success"),
            ("workoutError", "watch-banner-danger"),
        ]
        for item in workoutStates {
            let app = launchFixture(item.fixture)
            openActions(app)
            app.staticTexts["Climb Workout"].tap()
            XCTAssertTrue(
                app.descendants(matching: .any)
                    .matching(identifier: item.identifier).firstMatch
                    .waitForExistence(timeout: 10),
                "fixture \(item.fixture) should expose \(item.identifier)"
            )
            if item.fixture == "workoutRest" {
                let oneMinute = app.buttons["rest-target-60"]
                let twoMinutes = app.buttons["rest-target-120"]
                XCTAssertTrue(oneMinute.waitForExistence(timeout: 5))
                XCTAssertTrue(twoMinutes.waitForExistence(timeout: 5))
                assertFullyVisible(oneMinute, in: app, fixture: item.fixture)
                assertFullyVisible(twoMinutes, in: app, fixture: item.fixture)
                XCTAssertEqual(twoMinutes.value as? String, "Not selected")
                twoMinutes.tap()
                XCTAssertEqual(twoMinutes.value as? String, "Selected")
                XCTAssertEqual(oneMinute.value as? String, "Not selected")
            }
            app.terminate()
        }

        let forceStates: [(fixture: String, identifier: String)] = [
            ("forceIdle", "Connect Progressor"),
            ("forceConnecting", "Connecting…"),
            ("forceConnected", "force-session-finish"),
            ("forceLive", "Stop & Save"),
            ("forceSaved", "watch-banner-success"),
            ("forceError", "watch-banner-danger"),
        ]
        for item in forceStates {
            let app = launchFixture(item.fixture)
            openActions(app)
            app.staticTexts["Force Gauge"].tap()
            XCTAssertTrue(
                app.descendants(matching: .any)
                    .matching(identifier: item.identifier).firstMatch
                    .waitForExistence(timeout: 10),
                "fixture \(item.fixture) should expose \(item.identifier)"
            )
            if item.fixture == "forceSaved" {
                let exercise = app.buttons["force-exercise-picker"]
                let side = app.buttons["force-side-picker"]
                XCTAssertTrue(exercise.waitForExistence(timeout: 5))
                XCTAssertTrue(side.waitForExistence(timeout: 5))
                app.swipeUp()
                assertFullyVisible(exercise, in: app, fixture: item.fixture)
                assertFullyVisible(side, in: app, fixture: item.fixture)
            }
            if item.fixture == "forceConnected" {
                let finish = app.buttons["force-session-finish"]
                let exercise = app.buttons["force-exercise-picker"]
                let side = app.buttons["force-side-picker"]
                let disconnect = app.buttons["disconnect-progressor"]
                for control in [finish, exercise, side, disconnect] {
                    XCTAssertTrue(
                        control.waitForExistence(timeout: 5),
                        "fixture \(item.fixture) should expose \(control.identifier)"
                    )
                }
                // The fixture starts at the session row, then proves the
                // setup controls remain reachable after the narrow 40mm
                // layout has been scrolled. The same assertions run on Ultra.
                assertFullyVisible(finish, in: app, fixture: item.fixture)
                app.swipeUp()
                assertFullyVisible(exercise, in: app, fixture: item.fixture)
                assertFullyVisible(side, in: app, fixture: item.fixture)
                assertFullyVisible(disconnect, in: app, fixture: item.fixture)
            }
            if item.fixture == "forceLive" {
                let stopAndSave = app.buttons["force-stop-save"]
                XCTAssertTrue(stopAndSave.waitForExistence(timeout: 5))
                assertFullyVisible(stopAndSave, in: app, fixture: item.fixture)
            }
            app.terminate()
        }
    }

    func testAppStoreScreenshots() throws {
        let app = XCUIApplication()
        setupSnapshot(app, waitForAnimations: true)
        app.launch()

        let readiness = app.descendants(matching: .any)
            .matching(identifier: "readiness-ring").firstMatch
        XCTAssertTrue(readiness.waitForExistence(timeout: 15))
        XCTAssertEqual(readiness.label, "Readiness")
        XCTAssertEqual(readiness.value as? String, "82 out of 100, Push")

        let acwr = app.descendants(matching: .any)
            .matching(identifier: "acwr-risk-track").firstMatch
        XCTAssertTrue(acwr.waitForExistence(timeout: 5))
        XCTAssertEqual(acwr.label, "ACWR")
        XCTAssertEqual(acwr.value as? String, "1.08, Optimal")
        snapshot("01-watch-status")

        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["Force Gauge"].waitForExistence(timeout: 10))
        snapshot("02-watch-actions")
    }

    private func launchFixture(_ fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        setupSnapshot(app, waitForAnimations: false)
        app.launchArguments.append(contentsOf: ["-sendmeter-fixture", fixture])
        app.launch()
        return app
    }

    private func openActions(_ app: XCUIApplication) {
        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["Force Gauge"].waitForExistence(timeout: 10))
    }

    private func assertFullyVisible(_ element: XCUIElement, in app: XCUIApplication, fixture: String) {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let frame = element.frame
        let bounds = window.frame
        XCTAssertTrue(element.isHittable, "fixture \(fixture) control is not hittable")
        XCTAssertGreaterThanOrEqual(frame.height, 44, "fixture \(fixture) control lost its 44pt hit target")
        XCTAssertGreaterThanOrEqual(frame.width, 44, "fixture \(fixture) control lost its 44pt horizontal hit target")
        XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX, "fixture \(fixture) control is clipped on the left")
        XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX, "fixture \(fixture) control is clipped on the right")
        XCTAssertGreaterThanOrEqual(frame.minY, bounds.minY, "fixture \(fixture) control is clipped above")
        XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY, "fixture \(fixture) control is clipped below")
    }
}
