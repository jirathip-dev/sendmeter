import XCTest
import CoreGraphics
import ImageIO
import UIKit

private enum ForceScreenshotCaptureError: Error {
    case emptyFrame
}

private enum IconScreenshotCaptureError: Error {
    case emptyFrame
}

@MainActor
final class SendmeterWatchScreenshots: XCTestCase {
    /// The 40mm release gate: the primary setup path must fit before any
    /// scrolling, including with an accessibility Dynamic Type category.
    /// The same test is executed twice after setting the fixture's Dynamic
    /// Type environment; each run retains a real screen capture in its
    /// xcresult bundle.
    func testForceSetupPrimaryPathFitsWithoutScroll() throws {
        try assertForceSetupPrimaryPathFits(
            accessibilityLarge: false,
            captureName: "40mm-force-setup-default"
        )
    }

    func testForceSetupAccessibilityLargeTextFitsWithoutScroll() throws {
        try assertForceSetupPrimaryPathFits(
            accessibilityLarge: true,
            captureName: "40mm-force-setup-accessibility-large"
        )
    }

    /// #539 round-1 review F4: the AC ("Layout is verified at normal and at
    /// least one accessibility Dynamic Type size") was previously ticked on
    /// two byte-identical screenshots — `testDeterministicFixtureMatrix`
    /// never passed `accessibilityLarge: true`, so nothing in the suite
    /// actually launched Status under `-sendmeter-accessibility-large`. This
    /// does, and captures a real screenshot either way, so a future Dynamic
    /// Type change to `StatusView` gets a live check instead of a vacuous one.
    func testStatusFitsAtAccessibilityLargeType() throws {
        let app = launchFixture("status", accessibilityLarge: true)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let pager = homePagerViewport(in: app)
        XCTAssertTrue(pager.waitForExistence(timeout: 10))
        let readinessCard = app.descendants(matching: .any)
            .matching(identifier: "readiness-card").firstMatch
        XCTAssertTrue(readinessCard.waitForExistence(timeout: 10))
        let readinessRing = app.descendants(matching: .any)
            .matching(identifier: "readiness-ring").firstMatch
        XCTAssertTrue(readinessRing.waitForExistence(timeout: 10))

        let syncLabel = app.descendants(matching: .any)
            .matching(identifier: "status-sync-label").firstMatch
        XCTAssertTrue(syncLabel.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForStableFrame(readinessCard),
            "accessibility-large status card must settle before clipping checks"
        )
        assertNotClipped(readinessCard, in: pager, fixture: "status-ax-large")
        assertNotClipped(readinessRing, in: pager, fixture: "status-ax-large")
        assertNotClipped(syncLabel, in: pager, fixture: "status-ax-large")

        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "40mm-status-accessibility-large"
        capture.lifetime = .keepAlways
        add(capture)
    }

    /// #569: the shared icon primitive must expose every promised visual state
    /// in the real watch hierarchy at the simulator's native size. The same
    /// helper is run as two independent tests so a normal launch/termination
    /// cannot skip the accessibility-large assertions; the Canvas pins the
    /// fixture at both 40mm and 49mm.
    func testIconPrimitiveStatesAtNormal() throws {
        try assertIconPrimitiveStates(
            accessibilityLarge: false,
            captureName: "icon-primitives-normal"
        )
    }

    func testIconPrimitiveStatesAtAccessibilityLarge() throws {
        try assertIconPrimitiveStates(
            accessibilityLarge: true,
            captureName: "icon-primitives-accessibility-large"
        )
    }

    private func assertIconPrimitiveStates(
        accessibilityLarge: Bool,
        captureName: String
    ) throws {
        let app = launchFixture("iconPrimitives", accessibilityLarge: accessibilityLarge)
        defer { app.terminate() }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let viewport = app.descendants(matching: .any)
            .matching(identifier: "icon-primitives-viewport")
            .firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))

        let normal = app.buttons["icon-action-normal"]
        let disabled = app.buttons["icon-action-disabled"]
        let unselected = app.buttons["icon-nav-unselected"]
        let selected = app.buttons["icon-nav-selected"]
        for control in [normal, disabled, unselected, selected] {
            XCTAssertTrue(
                control.waitForExistence(timeout: 10),
                "icon fixture should expose \(control.identifier)"
            )
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
            assertNotClipped(
                control,
                in: viewport,
                fixture: accessibilityLarge ? "icon-primitives-ax-large" : "icon-primitives"
            )
        }
        XCTAssertTrue(normal.isEnabled)
        XCTAssertFalse(disabled.isEnabled)
        XCTAssertEqual(normal.label, "Normal icon action")
        XCTAssertEqual(disabled.label, "Disabled icon action")
        XCTAssertEqual(unselected.label, "Show status")
        XCTAssertEqual(selected.label, "Show actions")

        // The selected trait is the only selection announcement owned by
        // the primitive; there is deliberately no explicit
        // accessibilityValue("Selected") to announce it twice.
        if let value = selected.value as? String {
            XCTAssertFalse(
                value.localizedCaseInsensitiveContains("selected, selected"),
                "selected navigation must not duplicate its VoiceOver state"
            )
        }

        let pressed = app.descendants(matching: .any)
            .matching(identifier: "icon-action-pressed")
            .firstMatch
        XCTAssertTrue(pressed.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(pressed.frame.width, 44)
        XCTAssertGreaterThanOrEqual(pressed.frame.height, 44)
        assertNotClipped(
            pressed,
            in: viewport,
            fixture: accessibilityLarge ? "icon-primitives-ax-large" : "icon-primitives"
        )

        var validatedPNGData: Data?
        for _ in 0..<3 {
            // A watch can remain in reduced-luminance/AOD after launch even
            // while its accessibility tree is current. Wake only the
            // non-control chrome, then reassert every icon state before
            // accepting the framebuffer as screenshot evidence.
            let wakeChrome = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.17))
            wakeChrome.tap()
            Thread.sleep(forTimeInterval: 0.2)
            wakeChrome.tap()

            for control in [normal, disabled, unselected, selected] {
                XCTAssertTrue(
                    control.waitForExistence(timeout: 10),
                    "icon fixture should expose \(control.identifier) before capture"
                )
                XCTAssertGreaterThanOrEqual(control.frame.width, 44)
                XCTAssertGreaterThanOrEqual(control.frame.height, 44)
                assertNotClipped(
                    control,
                    in: viewport,
                    fixture: accessibilityLarge ? "icon-primitives-ax-large" : "icon-primitives"
                )
            }

            Thread.sleep(forTimeInterval: 1)
            let screenshot = app.screenshot()
            if let pngData = screenshot.image.pngData(),
               let source = CGImageSourceCreateWithData(pngData as CFData, nil),
               let encodedImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
               hasSelectedIconSurface(encodedImage) {
                validatedPNGData = pngData
                break
            }
        }
        guard let validatedPNGData else {
            XCTFail("icon primitive screenshot never rendered the selected cyan surface below the clock")
            throw IconScreenshotCaptureError.emptyFrame
        }

        // Attach the exact validated PNG bytes; screenshot/image convenience
        // initializers can re-read or re-render a watch framebuffer while it dims.
        let capture = XCTAttachment(data: validatedPNGData, uniformTypeIdentifier: "public.png")
        capture.name = captureName
        capture.lifetime = .keepAlways
        add(capture)
    }

    /// #580: the live Workout screen must hold every control — compact
    /// finish, four rest pills, play/stop — inside the viewport with real
    /// hit targets. The fixture drives the production hierarchy (same
    /// `WorkoutLiveView` control path as a real workout) while keeping
    /// ending and attempt persistence out of the test; the screenshot
    /// schemes run this against both the 40mm and 49mm destinations, and
    /// the second test repeats it at an accessibility Dynamic Type size.
    func testWorkoutLiveControlsFitAtNormalText() throws {
        try assertWorkoutLiveControls(
            accessibilityLarge: false,
            captureName: "workout-live-normal"
        )
    }

    func testWorkoutLiveControlsFitAtAccessibilityLargeText() throws {
        try assertWorkoutLiveControls(
            accessibilityLarge: true,
            captureName: "workout-live-accessibility-large"
        )
    }

    private func assertWorkoutLiveControls(
        accessibilityLarge: Bool,
        captureName: String
    ) throws {
        let app = launchFixture("workoutRest", accessibilityLarge: accessibilityLarge)
        defer { app.terminate() }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        openActions(app)
        tapHomeAction(app, identifier: "home-action-workout")

        let viewport = app.descendants(matching: .any)
            .matching(identifier: "workout-live-viewport")
            .firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))

        let finish = smallestButton(in: app, identifier: "finish-workout")
        let boulder = smallestButton(in: app, identifier: "workout-boulder-toggle")
        let restControls = [60, 120, 180, 300].map {
            smallestButton(in: app, identifier: "rest-target-\($0)")
        }

        XCTAssertTrue(finish.waitForExistence(timeout: 10))
        XCTAssertEqual(finish.label, "Finish workout")
        assertFullyVisible(finish, in: app, fixture: "workoutRest", viewport: viewport)
        XCTAssertTrue(boulder.waitForExistence(timeout: 10))
        XCTAssertEqual(boulder.label, "Start boulder")
        assertFullyVisible(boulder, in: app, fixture: "workoutRest", viewport: viewport)

        for control in restControls {
            XCTAssertTrue(control.waitForExistence(timeout: 10))
            assertRestPillVisible(control, in: app, viewport: viewport, fixture: "workoutRest")
        }
        // #582 review F1: the action row is the later sibling, so any pill /
        // play-stop hit-frame overlap silently routes taps on visible pill
        // pixels to Start/Stop boulder. The layout promises disjoint hit
        // frames (pill slots end at their visible bottom edge; the action
        // row pads by the full 7pt overhang) — hold it to that.
        let lowestPillHitEdge = restControls.map { $0.frame.maxY }.max() ?? .infinity
        XCTAssertGreaterThanOrEqual(
            boulder.frame.minY, lowestPillHitEdge,
            "play/stop hit frame must not overlap the rest pills' hit frames"
        )
        assertRestTargetSelection(restControls, selectedIndex: 2)
        assertWorkoutReadouts(app, accessibilityLarge: accessibilityLarge)

        // Exercise every direct target, including both endpoints, and verify
        // the shared setter drives exactly one selected accessibility state.
        // End back on the fixture default (3m) so the retained capture shows
        // the state the fixture describes.
        for selectedIndex in [0, 1, 3, 2] {
            restControls[selectedIndex].tap()
            assertRestTargetSelection(restControls, selectedIndex: selectedIndex)
        }

        // Capture the live state before opening the destructive confirmation:
        // watchOS can retain the prior system-sheet framebuffer after its
        // accessibility tree dismisses, so this ordering keeps the retained
        // PNG honest while the confirmation is verified immediately after.
        var validatedPNGData: Data?
        for _ in 0..<3 {
            // The watch can expose a fresh accessibility tree while its AOD
            // framebuffer is still blank. Wake the chrome (a dead spot above
            // the content, never a control), then repeat the geometry
            // assertions before retaining the screenshot bytes.
            let wakeChrome = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.17))
            wakeChrome.tap()
            Thread.sleep(forTimeInterval: 0.2)
            wakeChrome.tap()
            for control in [finish, boulder] + restControls {
                XCTAssertTrue(control.waitForExistence(timeout: 10))
            }
            assertFullyVisible(finish, in: app, fixture: "workoutRest", viewport: viewport)
            assertFullyVisible(boulder, in: app, fixture: "workoutRest", viewport: viewport)
            for control in restControls {
                assertRestPillVisible(control, in: app, viewport: viewport, fixture: "workoutRest")
            }

            Thread.sleep(forTimeInterval: 1)
            let screenshot = app.screenshot()
            if let pngData = screenshot.image.pngData(),
               let source = CGImageSourceCreateWithData(pngData as CFData, nil),
               let encodedImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
               hasWorkoutPhaseSurface(encodedImage) {
                validatedPNGData = pngData
                break
            }
        }
        guard let validatedPNGData else {
            XCTFail("workout fixture screenshot never rendered the live phase surface below the clock")
            throw ForceScreenshotCaptureError.emptyFrame
        }
        let capture = XCTAttachment(data: validatedPNGData, uniformTypeIdentifier: "public.png")
        capture.name = captureName
        capture.lifetime = .keepAlways
        add(capture)

        // The destructive control must ask first. Cancel the confirmation so
        // the fixture remains live and no workout is ended or saved by this
        // layout test.
        finish.tap()
        // watchOS presents confirmation actions in a system sheet and does
        // not retain caller-supplied identifiers on those action cells; the
        // visible destructive title is the stable semantic contract here.
        let confirm = app.buttons["Finish Workout"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        let cancel = app.buttons.matching(identifier: "AX_ActionContentControllerCancelButton").firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        XCTAssertTrue(waitForElementToDisappear(confirm), "finish confirmation action must dismiss after Cancel")
        XCTAssertTrue(waitForElementToDisappear(cancel), "finish confirmation sheet must dismiss after Cancel")
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        XCTAssertEqual(finish.label, "Finish workout")
    }

    /// #539 navigation regression guard: use the explicit Home controls for
    /// both destinations and for the return path. This stays intentionally
    /// separate from the visual matrix so a failed destination hit test is
    /// not hidden by a later fixture assertion or a page gesture.
    func testHomeNavigationUsesIdentifiedControls() throws {
        let destinations: [(fixture: String, identifier: String, expected: String)] = [
            ("forceSetup", "home-action-force", "force-context-button"),
            ("workoutIdle", "home-action-workout", "Start Workout"),
        ]

        for item in destinations {
            let app = launchFixture(item.fixture)
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            openActions(app)
            tapHomeAction(app, identifier: item.identifier)
            let destination = app.descendants(matching: .any)
                .matching(identifier: item.expected).firstMatch
            if item.expected == "Start Workout" {
                XCTAssertTrue(
                    app.buttons["Start Workout"].waitForExistence(timeout: 10),
                    "fixture \(item.fixture) should reach the Workout destination"
                )
            } else {
                XCTAssertTrue(
                    destination.waitForExistence(timeout: 10),
                    "fixture \(item.fixture) should reach the Force destination"
                )
            }
            app.terminate()
        }

        let app = launchFixture("status")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let actions = app.buttons.matching(identifier: "home-nav-actions").firstMatch
        let status = app.buttons.matching(identifier: "home-nav-status").firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        actions.tap()
        XCTAssertTrue(app.staticTexts["Force Gauge"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForStableFrame(app.staticTexts["Force Gauge"], timeout: 5),
            "Actions page must settle before identified return tap"
        )
        status.tap()
        let card = app.descendants(matching: .any)
            .matching(identifier: "readiness-card").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForStableFrame(card, timeout: 5),
            "Status page must settle after identified return tap"
        )
        app.terminate()
    }

    private func assertForceSetupPrimaryPathFits(
        accessibilityLarge: Bool,
        captureName: String
    ) throws {
        let app = launchFixture(
            "forceSetup",
            accessibilityLarge: accessibilityLarge
        )
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 10),
            "40mm setup fixture must remain foreground before navigation"
        )
        openActions(app)
        tapHomeAction(app, identifier: "home-action-force")

        // SL-537: the redesigned setup screen centers on one ready/start
        // card with a compact top-right context action (exercise/side/
        // protocol now live one tap away in the chooser, not as separate
        // main-screen controls) and Free hold as the explicit manual
        // fallback. Disconnect and connection state are demoted below the
        // fold — this primary path (context action, ready/start card, Free
        // hold) is the no-scroll guarantee, not the whole screen.
        let context = app.buttons["force-context-button"]
        let start = app.buttons
            .matching(NSPredicate(format: "label == %@", "Start selected protocol"))
            .firstMatch
        let freeHold = app.buttons["force-free-hold"]

        let controls = [context, start, freeHold]
        // SL-538 round-2 review finding 5: a future eligibility regression
        // (Start disabled, `.opacity(0.52)`) would otherwise fail the pixel
        // scan below with a colour-shaped error message pointing at the
        // wrong cause. Assert the actual precondition first.
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(start.isEnabled, "Start must be enabled for the pixel scan below to mean anything")
        var validatedPNGData: Data?
        for _ in 0..<3 {
            // A watch can remain in reduced-luminance/AOD after the navigation
            // tap even while its accessibility tree is current. Wake only the
            // non-control chrome, then reassert every setup control before capture.
            let wakeChrome = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.17))
            wakeChrome.tap()
            Thread.sleep(forTimeInterval: 0.2)
            wakeChrome.tap()

            for control in controls {
                XCTAssertTrue(
                    control.waitForExistence(timeout: 10),
                    "40mm setup should expose \(control.identifier) before any scroll"
                )
                assertFullyVisible(control, in: app, fixture: "forceSetup")
            }
            // Strengthened (SL-537): prove the actual hierarchy, not just
            // that each control happens to be present — the context action
            // reads at/near the top of the ready/start card (it's a small
            // corner overlay, so a few points of inset padding is expected),
            // which itself sits above Free hold.
            XCTAssertLessThanOrEqual(
                context.frame.minY, start.frame.minY + 8,
                "the compact context action must read at the top of the ready/start card, not below it"
            )
            XCTAssertLessThanOrEqual(
                start.frame.maxY, freeHold.frame.minY,
                "Free hold must not overlap or outrank the ready/start card"
            )
            // Disconnect is demoted to a secondary/passive action (#537 #4):
            // it must not be part of the no-scroll primary path. Round-1
            // review finding 6: an identifier-only lookup lets this pass
            // vacuously if the identifier ever stops resolving (watchOS has
            // been observed collapsing descendant identifiers onto a
            // container elsewhere in this same view tree) — match by
            // identifier OR label, same predicate the matrix test already
            // uses for this exact control, so a lost identifier still finds
            // the button and the assertion means what it says.
            let disconnect = app.buttons
                .matching(
                    NSPredicate(
                        format: "identifier == %@ OR label == %@",
                        "disconnect-progressor",
                        "Disconnect Progressor"
                    )
                )
                .firstMatch
            XCTAssertFalse(
                disconnect.exists && disconnect.isHittable && disconnect.frame.maxY <= freeHold.frame.maxY + 4,
                "disconnect must not compete with the primary path for the initial viewport"
            )

            Thread.sleep(forTimeInterval: 1)
            let screenshot = app.screenshot()
            if let pngData = screenshot.image.pngData(),
               let source = CGImageSourceCreateWithData(pngData as CFData, nil),
               let encodedImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
               hasPrimaryStartSurface(encodedImage) {
                validatedPNGData = pngData
                break
            }
        }
        guard let validatedPNGData else {
            XCTFail("40mm setup screenshot never rendered the semantic-primary Start surface")
            throw ForceScreenshotCaptureError.emptyFrame
        }
        // Attach the exact validated PNG bytes; screenshot/image convenience
        // initializers can re-read or re-render the watch framebuffer while it dims.
        let capture = XCTAttachment(data: validatedPNGData, uniformTypeIdentifier: "public.png")
        capture.name = captureName
        capture.lifetime = .keepAlways
        add(capture)
    }

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
            // #539 round-1 review F1/F3: the three sync states with the
            // longest real `syncLabel`/chip-title strings — nothing exercised
            // these before, which is how the round-1 fix shipped verified
            // against a card production never renders.
            ("statusAuthRequired", "watch-state-warning"),
            ("statusUnsupported", "watch-state-warning"),
            ("statusFailed", "watch-state-warning"),
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
                // #539 round-1 review F5: identifier-based, not copy-based —
                // a label change can no longer silently break this guard.
                let statusPage = app.buttons.matching(identifier: "home-nav-status").firstMatch
                let actionsPage = app.buttons.matching(identifier: "home-nav-actions").firstMatch
                XCTAssertTrue(statusPage.waitForExistence(timeout: 5))
                XCTAssertTrue(actionsPage.waitForExistence(timeout: 5))
                assertFullyVisible(statusPage, in: app, fixture: item.fixture)
                assertFullyVisible(actionsPage, in: app, fixture: item.fixture)
                let pager = homePagerViewport(in: app)
                XCTAssertTrue(pager.waitForExistence(timeout: 5))
                let readiness = app.descendants(matching: .any)
                    .matching(identifier: "readiness-ring").firstMatch
                XCTAssertTrue(readiness.waitForExistence(timeout: 5))
                XCTAssertLessThanOrEqual(
                    statusPage.frame.maxY,
                    readiness.frame.minY,
                    "home page selector must stay above readiness content"
                )
                XCTAssertFalse(
                    statusPage.frame.intersects(readiness.frame),
                    "home page selector must never obscure readiness content"
                )
                actionsPage.tap()
                XCTAssertTrue(app.staticTexts["Force Gauge"].waitForExistence(timeout: 5))
                XCTAssertTrue(
                    waitForStableFrame(app.staticTexts["Force Gauge"], timeout: 5),
                    "Actions page must settle before returning to Status"
                )
                statusPage.tap()
                let returningCard = app.descendants(matching: .any)
                    .matching(identifier: "readiness-card").firstMatch
                XCTAssertTrue(returningCard.waitForExistence(timeout: 5))
                XCTAssertTrue(
                    waitForStableFrame(returningCard, timeout: 5),
                    "status page must settle after returning from Actions"
                )
            }
            if item.fixture.hasPrefix("status") {
                // #539 round-1 review F1: assert against the REAL production
                // card — the ring near its top AND whichever explanatory line
                // it renders at the bottom (every fixture used to suppress
                // both entirely, which is exactly how the round-1 fix shipped
                // verified against a shorter stand-in). This is the
                // regression guard for the clipping bug, independent of the
                // curated App Store screenshots.
                let readinessRing = app.descendants(matching: .any)
                    .matching(identifier: "readiness-ring").firstMatch
                XCTAssertTrue(readinessRing.waitForExistence(timeout: 5), "fixture \(item.fixture) should expose readiness-ring")
                let pager = homePagerViewport(in: app)
                XCTAssertTrue(pager.waitForExistence(timeout: 5), "fixture \(item.fixture) should expose the real pager viewport")
                let readinessCard = app.descendants(matching: .any)
                    .matching(identifier: "readiness-card").firstMatch
                XCTAssertTrue(readinessCard.waitForExistence(timeout: 5), "fixture \(item.fixture) should expose readiness-card")
                XCTAssertTrue(
                    waitForStableFrame(readinessCard),
                    "fixture \(item.fixture) status card must settle before clipping checks"
                )
                // The card itself is the load-bearing assertion: checking only
                // the ring can pass while the bottom border and sync guidance
                // are still behind TabView's `.clipped()` boundary.
                assertNotClipped(readinessCard, in: pager, fixture: item.fixture)
                assertNotClipped(readinessRing, in: pager, fixture: item.fixture)
                // Empty/offline states render the full phone-sync guidance as
                // visible content (the ring announces only "No data" to avoid
                // duplicate VoiceOver copy), so they get the same load-bearing
                // frame assertion as scored states.
                let nilReadinessFixtures: Set<String> = ["statusEmpty", "statusOffline"]
                if nilReadinessFixtures.contains(item.fixture) {
                    let guidance = app.descendants(matching: .any)
                        .matching(identifier: "readiness-empty-guidance").firstMatch
                    XCTAssertTrue(guidance.waitForExistence(timeout: 5), "fixture \(item.fixture) should expose readiness-empty-guidance")
                    XCTAssertEqual(guidance.label, "Open Sendmeter on your iPhone to sync Health")
                    assertNotClipped(guidance, in: pager, fixture: item.fixture)
                    let capture = XCTAttachment(screenshot: app.screenshot())
                    capture.name = "\(item.fixture)-guidance"
                    capture.lifetime = .keepAlways
                    add(capture)
                } else {
                    let syncLabel = app.descendants(matching: .any)
                        .matching(identifier: "status-sync-label").firstMatch
                    XCTAssertTrue(syncLabel.waitForExistence(timeout: 5), "fixture \(item.fixture) should expose status-sync-label")
                    assertNotClipped(syncLabel, in: pager, fixture: item.fixture)
                }
                // Keep one retained frame for every status variant, not only
                // empty/offline. This makes the exported evidence cover the
                // requested auth-required, unsupported and failed cards too,
                // including their bottom edge after the frame assertions.
                let statusCapture = XCTAttachment(screenshot: app.screenshot())
                statusCapture.name = "\(item.fixture)-status"
                statusCapture.lifetime = .keepAlways
                add(statusCapture)
                // #539 round-1 review F3: the state chip (shares a row with
                // the eyebrow now) must stay fully within the card even at
                // its longest real titles, not merely present. Not a tap
                // target, so no 44pt hit-target requirement — `assertNotClipped`,
                // not `assertFullyVisible`.
                let chip = app.descendants(matching: .any)
                    .matching(identifier: item.identifier).firstMatch
                assertNotClipped(chip, in: pager, fixture: item.fixture)
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
            // #580: End moved out of the toolbar into the compact icon-only
            // finish action; the rest-pill selection/geometry matrix lives in
            // `assertWorkoutLiveControls`, which also runs accessibility-large.
            ("workoutLive", "finish-workout"),
            ("workoutRest", "finish-workout"),
            ("workoutSaved", "watch-state-success"),
            ("workoutError", "watch-banner-danger"),
        ]
        for item in workoutStates {
            let app = launchFixture(item.fixture)
            openActions(app)
            tapHomeAction(app, identifier: "home-action-workout")
            XCTAssertTrue(
                app.descendants(matching: .any)
                    .matching(identifier: item.identifier).firstMatch
                    .waitForExistence(timeout: 10),
                "fixture \(item.fixture) should expose \(item.identifier)"
            )
            if item.fixture == "workoutLive" {
                // The climbing state is the one `assertWorkoutLiveControls`
                // does not pose: the in-row toggle must read as the boulder
                // stop — a different scope (and glyph) than the finish flag.
                let boulder = smallestButton(in: app, identifier: "workout-boulder-toggle")
                XCTAssertTrue(boulder.waitForExistence(timeout: 5))
                XCTAssertEqual(boulder.label, "Stop boulder")
                assertFullyVisible(boulder, in: app, fixture: item.fixture)
            }
            app.terminate()
        }

        let forceStates: [(fixture: String, identifier: String)] = [
            // Movement Starter remains cadence-eligible without a connected
            // Progressor, so idle exposes the Start card rather than Connect.
            ("forceIdle", "force-start-selected"),
            ("forceConnecting", "Connecting…"),
            ("forceConnected", "force-session-finish"),
            ("forceLive", "Stop & Save"),
            ("forceSaved", "watch-banner-success"),
            ("forceError", "watch-banner-danger"),
        ]
        for item in forceStates {
            let app = launchFixture(item.fixture)
            openActions(app)
            tapHomeAction(app, identifier: "home-action-force")
            XCTAssertTrue(
                app.descendants(matching: .any)
                    .matching(identifier: item.identifier).firstMatch
                    .waitForExistence(timeout: 10),
                "fixture \(item.fixture) should expose \(item.identifier)"
            )
            if item.fixture == "forceIdle" {
                let start = app.buttons["force-start-selected"]
                XCTAssertTrue(start.waitForExistence(timeout: 5))
                XCTAssertTrue(start.isEnabled, "cadence-only Start must be enabled with the fixture exercise selected")
                XCTAssertTrue(start.isHittable, "cadence-only Start must be hittable while disconnected")
            }
            if item.fixture == "forceSaved" || item.fixture == "forceConnected" {
                // SL-537: exercise/side now live behind the one compact
                // top-right context action rather than as separate
                // main-screen controls.
                let context = app.buttons["force-context-button"]
                XCTAssertTrue(
                    context.waitForExistence(timeout: 5),
                    "fixture \(item.fixture) should expose the compact context action"
                )
                assertFullyVisible(context, in: app, fixture: item.fixture)
                context.tap()
                // Both fixtures set tag "Crimp edge" and a canonical lowercase
                // side (see `ScreenshotFixtures.force`). The chooser itself was never
                // part of the no-scroll guarantee — only Force setup's
                // primary path is — and Side plus the first exercise row
                // don't both fit the 40mm viewport at once. Side is near the
                // top, but the selected side row may be below the initial
                // viewport; tapping lets XCUITest scroll it into view.
                let sideOption = app.buttons[
                    item.fixture == "forceConnected" ? "force-side-right" : "force-side-left"
                ]
                XCTAssertTrue(sideOption.waitForExistence(timeout: 5), "chooser should expose the Side control")
                XCTAssertEqual(sideOption.value as? String, "Selected")
                sideOption.tap()
                XCTAssertEqual(sideOption.value as? String, "Selected")

                if item.fixture == "forceConnected" {
                    let leftOption = app.buttons["force-side-left"]
                    XCTAssertTrue(leftOption.waitForExistence(timeout: 5))
                    leftOption.tap()
                    XCTAssertEqual(leftOption.value as? String, "Selected")
                    XCTAssertEqual(sideOption.value as? String, "Not selected")
                    sideOption.tap()
                    XCTAssertEqual(sideOption.value as? String, "Selected")
                    XCTAssertEqual(leftOption.value as? String, "Not selected")
                }

                // Exercise rows are below the new four-row vertical Side
                // list inside a LazyVStack, so they are not necessarily
                // materialized immediately after opening the chooser. Use
                // the same bounded scroll-to-find pattern as the Suggested
                // protocol coverage above before checking existence.
                let exerciseRow = app.buttons["force-exercise-Crimp edge"]
                for _ in 0..<6 where !exerciseRow.exists {
                    app.swipeUp(velocity: .slow)
                }
                XCTAssertTrue(exerciseRow.waitForExistence(timeout: 5), "chooser should list the fixture's exercise")
                app.buttons["BackButton"].tap()
                XCTAssertTrue(
                    context.waitForExistence(timeout: 5),
                    "tapping Back should return to Force setup"
                )
                if item.fixture == "forceConnected" {
                    let readyContext = app.descendants(matching: .any)
                        .matching(NSPredicate(
                            format: "label CONTAINS %@ AND label CONTAINS %@",
                            "Crimp edge",
                            "Right"
                        ))
                        .firstMatch
                    XCTAssertTrue(
                        readyContext.waitForExistence(timeout: 5),
                        "ready context should reflect the selected Right side after returning from the chooser"
                    )
                }
            }
            if item.fixture == "forceConnected" {
                let finish = app.buttons["force-session-finish"]
                XCTAssertTrue(
                    finish.waitForExistence(timeout: 5),
                    "fixture \(item.fixture) should expose \(finish.identifier)"
                )
                assertFullyVisible(finish, in: app, fixture: item.fixture)

                // Disconnect is demoted to a passive/secondary action (#537
                // #4) — still reachable, but only after scrolling past the
                // primary ready path.
                let disconnect = app.buttons
                    .matching(
                        NSPredicate(
                            format: "identifier == %@ OR label == %@",
                            "disconnect-progressor",
                            "Disconnect Progressor"
                        )
                    )
                    .firstMatch
                for _ in 0..<6 where !disconnect.isHittable {
                    app.swipeUp(velocity: .slow)
                }
                XCTAssertTrue(
                    disconnect.waitForExistence(timeout: 5),
                    "fixture \(item.fixture) should expose \(disconnect.identifier) after scrolling"
                )
                assertFullyVisible(disconnect, in: app, fixture: item.fixture)
            }
            if item.fixture == "forceLive" {
                let stopAndSave = app.buttons["force-stop-save"]
                XCTAssertTrue(stopAndSave.waitForExistence(timeout: 5))
                let viewport = app.windows.firstMatch.frame
                for _ in 0..<3 where !stopAndSave.isHittable || stopAndSave.frame.maxY > viewport.maxY {
                    app.swipeUp(velocity: .slow)
                }
                assertFullyVisible(stopAndSave, in: app, fixture: item.fixture)
                let evidence = XCTAttachment(screenshot: app.screenshot())
                evidence.name = "force-live-trace"
                evidence.lifetime = .keepAlways
                add(evidence)
            }
            app.terminate()
        }
    }

    /// SL-538 round-2 review finding 1: `ForceProtocolViews.swift` was the
    /// single most-changed file in the original commit (16 call sites
    /// retinted) and had zero fixture/screenshot coverage. Navigates the
    /// real production chooser (no mock) via the always-available Suggested
    /// Movement Starter row, which needs neither network nor a signed-in
    /// relay to render.
    func testForceProtocolChooserRendersSuggestedProtocol() throws {
        let app = launchFixture("forceSetup")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        openActions(app)
        tapHomeAction(app, identifier: "home-action-force")

        let contextButton = app.buttons["force-context-button"]
        XCTAssertTrue(
            contextButton.waitForExistence(timeout: 10),
            "setup should expose the compact context action before opening the chooser"
        )
        contextButton.tap()

        // SL-537: Side and Exercise sections now sit above Suggested/My
        // protocols in this same chooser (it's the one compact top-level
        // selector for all three), so the LazyVStack no longer materializes
        // the Suggested row until the view scrolls near it.
        let suggestedRow = app.buttons["force-protocol-suggested:movement-starter"]
        let viewport = app.windows.firstMatch.frame
        // The chooser's four side rows plus exercise/catalog sections can
        // require several bounded drags on a 40mm watch. Keep the loop finite
        // and calibrate each correction from the row's actual frame: fixed
        // nudges either left the row 53pt above the viewport or over-corrected
        // it 64pt below it on watchOS 26.
        for _ in 0..<60 {
            if suggestedRow.exists {
                let frame = suggestedRow.frame
                if suggestedRow.isHittable,
                   frame.minY >= viewport.minY,
                   frame.maxY <= viewport.maxY {
                    break
                }
                if frame.minY < viewport.minY {
                    dragChooser(
                        app,
                        viewport: viewport,
                        points: viewport.minY - frame.minY + 12,
                        contentDirection: 1
                    )
                    continue
                }
                if frame.maxY > viewport.maxY {
                    dragChooser(
                        app,
                        viewport: viewport,
                        points: frame.maxY - viewport.maxY + 12,
                        contentDirection: -1
                    )
                    continue
                }
            }
            // The row may not yet be materialized by LazyVStack; advance by a
            // small bounded amount until its frame becomes queryable.
            dragChooser(
                app,
                viewport: viewport,
                points: min(viewport.height * 0.12, 24),
                contentDirection: -1
            )
        }
        XCTAssertTrue(
            suggestedRow.waitForExistence(timeout: 10),
            "chooser should list the Suggested Movement Starter protocol"
        )
        // Keep the protocol itself in the retained attachment. Existence alone
        // can pass while a lazy row is offscreen, producing a footer-only
        // screenshot that proves nothing about the picker presentation.
        assertFullyVisible(suggestedRow, in: app, fixture: "forceSetup")

        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "force-protocol-chooser"
        capture.lifetime = .keepAlways
        add(capture)
    }

    /// Move the chooser content by a measured number of screen points. Using
    /// the window's normalized center keeps the gesture inside the ScrollView,
    /// while deriving the endpoint from `points` avoids the fixed-nudge
    /// overshoot that made the retained chooser screenshot prove a clipped
    /// row instead of a visible one.
    private func dragChooser(
        _ app: XCUIApplication,
        viewport: CGRect,
        points: CGFloat,
        contentDirection: CGFloat
    ) {
        let boundedPoints = min(max(points, 4), viewport.height * 0.3)
        let normalizedDelta = boundedPoints / viewport.height
        let startY: CGFloat = 0.5
        let endY = min(max(startY + contentDirection * normalizedDelta, 0.15), 0.85)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY))
        start.press(
            forDuration: 0.1,
            thenDragTo: end,
            withVelocity: .slow,
            thenHoldForDuration: 0
        )
    }

    /// SL-538 round-2 review finding 1: `GuidedForceRunnerView.swift` (12
    /// retinted call sites) also had zero coverage. The real
    /// `GuidedForceRunner` needs a relayed signed-in account to start a run,
    /// which this standalone watch-target test cannot provide honestly — the
    /// `forceGuidedRun` fixture instead renders the production view directly
    /// with fixed display data (`RootView`'s fixture bypass +
    /// `GuidedForceRunnerView.display`), the same presentation-only pattern
    /// `forceSetup`/`forceConnected`/etc. already use for `ForceGaugeView`.
    func testForceGuidedRunRendersActivePhase() throws {
        let app = launchFixture("forceGuidedRun")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let stop = app.buttons["force-guided-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "fixture should render the Stop control")
        assertFullyVisible(stop, in: app, fixture: "forceGuidedRun")

        let phaseCard = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier == %@ OR identifier == %@ OR identifier == %@",
                "force-guided-phase-card", "force-guided-compact-card", "force-guided-micro-card"
            ))
            .firstMatch
        XCTAssertTrue(phaseCard.waitForExistence(timeout: 5), "fixture should render one of the phase-card layouts")

        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "force-guided-run"
        capture.lifetime = .keepAlways
        add(capture)
    }

    func testAppStoreScreenshots() throws {
        let app = XCUIApplication()
        setupSnapshot(app, waitForAnimations: true)
        app.launch()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "App Store fixture must reach the foreground before navigation"
        )
        // Snapshot launch arguments select the deterministic `.status` fixture,
        // but the paged TabView still has a real transition state. Drive the
        // explicit status control and wait for the card/viewport geometry to
        // settle before taking the first attachment; element existence alone
        // previously allowed a blank Ultra status frame to pass.
        let statusPage = app.buttons.matching(identifier: "home-nav-status").firstMatch
        XCTAssertTrue(statusPage.waitForExistence(timeout: 10))
        statusPage.tap()

        let pager = homePagerViewport(in: app)
        XCTAssertTrue(pager.waitForExistence(timeout: 10))
        let readinessCard = app.descendants(matching: .any)
            .matching(identifier: "readiness-card").firstMatch
        XCTAssertTrue(readinessCard.waitForExistence(timeout: 10))
        let readiness = app.descendants(matching: .any)
            .matching(identifier: "readiness-ring").firstMatch
        XCTAssertTrue(readiness.waitForExistence(timeout: 15))
        XCTAssertEqual(readiness.label, "Readiness")
        XCTAssertEqual(readiness.value as? String, "82 out of 100, Push")

        let syncLabel = app.descendants(matching: .any)
            .matching(identifier: "status-sync-label").firstMatch
        XCTAssertTrue(syncLabel.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForStableFrame(readinessCard),
            "App Store status page must settle before capture"
        )
        assertNotClipped(readinessCard, in: pager, fixture: "appstore-status")
        assertNotClipped(readiness, in: pager, fixture: "appstore-status")
        assertNotClipped(syncLabel, in: pager, fixture: "appstore-status")

        let acwr = app.descendants(matching: .any)
            .matching(identifier: "acwr-risk-track").firstMatch
        XCTAssertTrue(acwr.waitForExistence(timeout: 5))
        XCTAssertEqual(acwr.label, "ACWR")
        XCTAssertEqual(acwr.value as? String, "1.08, Optimal")
        snapshot("01-watch-status")
        let statusEvidence = XCTAttachment(screenshot: app.screenshot())
        statusEvidence.name = "appstore-status"
        statusEvidence.lifetime = .keepAlways
        add(statusEvidence)

        let actionsPage = app.buttons.matching(identifier: "home-nav-actions").firstMatch
        XCTAssertTrue(actionsPage.waitForExistence(timeout: 10))
        actionsPage.tap()
        XCTAssertTrue(app.staticTexts["Force Gauge"].waitForExistence(timeout: 10))
        let forceGauge = app.staticTexts["Force Gauge"]
        XCTAssertTrue(
            waitForStableFrame(forceGauge),
            "App Store Actions page must settle before capture"
        )
        snapshot("02-watch-actions")
        let actionsEvidence = XCTAttachment(screenshot: app.screenshot())
        actionsEvidence.name = "appstore-actions"
        actionsEvidence.lifetime = .keepAlways
        add(actionsEvidence)
    }

    private func launchFixture(
        _ fixture: String,
        accessibilityLarge: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        setupSnapshot(app, waitForAnimations: false)
        app.launchArguments.append(contentsOf: ["-sendmeter-fixture", fixture])
        if accessibilityLarge {
            app.launchArguments.append("-sendmeter-accessibility-large")
        }
        app.launch()
        return app
    }

    private func openActions(_ app: XCUIApplication) {
        // Drive the same explicit selector used by the App Store path. A
        // gesture can leave page-style TabView mid-transition (or on the
        // previous page after a retained fixture), making a descendant label
        // exist but have no hittable coordinate.
        let actions = app.buttons.matching(identifier: "home-nav-actions").firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.tap()

        let forceGauge = app.staticTexts["Force Gauge"]
        XCTAssertTrue(forceGauge.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForStableFrame(forceGauge),
            "Actions page must settle before destination navigation"
        )
    }

    private func tapHomeAction(_ app: XCUIApplication, identifier: String) {
        let action = app.buttons.matching(identifier: identifier).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 10), "Home action \(identifier) should be available")
        XCTAssertTrue(waitForStableFrame(action), "Home action \(identifier) must settle before tapping")
        if identifier == "home-action-workout" {
            // The workout card follows Force in the compact Actions scroll
            // view. Bring its own hit target into the active window before
            // synthesizing a tap; otherwise watchOS can report the visible
            // descendant's stale pre-scroll frame and route the tap nowhere.
            // Measured drags (same calibration as `dragChooser`) instead of
            // blind `swipeUp`s: a momentum swipe can overshoot and leave the
            // card parked half outside the window, which is what used to
            // make the hard hittability guard below look flaky. The guard
            // itself stays hard — it is the #539 regression check for this
            // exact control and must not be weakened (#582 review F2).
            let viewport = app.windows.firstMatch.frame
            for _ in 0..<8 {
                let frame = action.frame
                if action.isHittable, frame.minY >= viewport.minY, frame.maxY <= viewport.maxY {
                    break
                }
                if frame.maxY > viewport.maxY {
                    dragChooser(
                        app,
                        viewport: viewport,
                        points: frame.maxY - viewport.maxY + 12,
                        contentDirection: -1
                    )
                } else if frame.minY < viewport.minY {
                    dragChooser(
                        app,
                        viewport: viewport,
                        points: viewport.minY - frame.minY + 12,
                        contentDirection: 1
                    )
                } else {
                    // Fully inside yet not hittable: the scroll view is still
                    // settling (or rubber-banding) — a small nudge forces a
                    // fresh layout pass.
                    dragChooser(app, viewport: viewport, points: 8, contentDirection: -1)
                }
                Thread.sleep(forTimeInterval: 0.3)
            }
            XCTAssertTrue(
                waitForStableFrame(action, timeout: 5),
                "Home action \(identifier) must settle after scrolling into view"
            )
        }
        XCTAssertTrue(action.isHittable, "Home action \(identifier) must be hittable before tapping")
        action.tap()
    }

    /// watchOS can expose a styled button through more than one accessibility
    /// node carrying the same identifier (a layout wrapper plus the styled
    /// label), and an identifier on a container has been observed swallowing
    /// its descendants' (`ForceGaugeView`'s documented footgun). Selecting
    /// the LARGEST match would let a huge container satisfy every `>= 44`
    /// geometry check vacuously (#582 review F5) — pick the smallest match,
    /// which biases every assertion toward failing, and flag duplicates so a
    /// silently split node is a finding rather than a coin toss.
    private func smallestButton(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let query = app.buttons.matching(identifier: identifier)
        let matches = query.allElementsBoundByIndex
        XCTAssertLessThanOrEqual(
            matches.count, 1,
            "expected one button for \(identifier), found \(matches.count) — geometry checks would be ambiguous"
        )
        return matches.min {
            ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height)
        } ?? query.firstMatch
    }

    private func waitForAccessibilityValue(
        _ element: XCUIElement,
        expected: String,
        timeout: TimeInterval = 3
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, (element.value as? String) == expected {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return (element.value as? String) == expected
    }

    private func waitForElementToDisappear(
        _ element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// A rendered pixel elsewhere on a watch framebuffer is not proof that
    /// the live Workout screen rendered its readouts. Pin the fixture's
    /// semantic values too, so accessibility-large truncation (for example
    /// `142` becoming `1…`) fails before a misleading capture is retained.
    private func assertWorkoutReadouts(_ app: XCUIApplication, accessibilityLarge: Bool) {
        for label in ["142", "46:33", "RESTING", "02:07", "12", "341 kcal", "1.4m"] {
            let readout = app.staticTexts[label]
            XCTAssertTrue(
                readout.waitForExistence(timeout: 5),
                "workout fixture readout \(label) must render completely"
            )
        }
        // #582 review F3: the accessibility-large run must exercise a
        // genuinely different render, or it can never fail differently from
        // the normal run. The HR readout is the screen's Dynamic
        // Type-scalable text (capped at .xxLarge, where the fixed 30pt row
        // stops fitting), so under `-sendmeter-accessibility-large` it must
        // render measurably taller than at the normal size — watchOS body
        // is ~17-18.5pt tall at normal sizes and ~21-23pt at .xxLarge, so
        // 20 sits between them. This fails if the whole screen is ever
        // re-capped at .large, and also if width pressure quietly hands the
        // growth back via `minimumScaleFactor` (how F3 originally hid).
        if accessibilityLarge {
            let heartRate = app.staticTexts["142"]
            XCTAssertGreaterThanOrEqual(
                heartRate.frame.height, 20,
                "accessibility-large must scale the HR readout (got \(heartRate.frame.height)pt) — the Dynamic Type cap has collapsed to the normal size"
            )
        }
    }

    /// #580: four rest pills share one 40mm row, so a literal 44pt-wide
    /// target per pill cannot exist (4 × 44 > the 162pt panel). The contract
    /// is: full 44pt-tall hit slot, an equal ≥36pt-wide share of the row
    /// (the real 40mm width is ~37.5pt — the floor sits just under it so a
    /// genuine shrink fails, #582 review F6), hittable, and zero clipping
    /// against the window and the live viewport.
    private func assertRestPillVisible(
        _ element: XCUIElement,
        in app: XCUIApplication,
        viewport: XCUIElement,
        fixture: String
    ) {
        XCTAssertTrue(element.isHittable, "fixture \(fixture) rest pill is not hittable")
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, "fixture \(fixture) rest pill lost its vertical 44pt target")
        XCTAssertGreaterThanOrEqual(element.frame.width, 36, "fixture \(fixture) rest pill lost its width share of the row")
        assertNotClipped(element, in: app, fixture: fixture)
        assertNotClipped(element, in: viewport, fixture: fixture)
    }

    private func assertRestTargetSelection(
        _ controls: [XCUIElement],
        selectedIndex: Int
    ) {
        for (index, control) in controls.enumerated() {
            let expected = index == selectedIndex ? "Selected" : "Not selected"
            XCTAssertTrue(
                waitForAccessibilityValue(control, expected: expected),
                "rest target index \(index) should announce \(expected)"
            )
        }
    }

    private func homePagerViewport(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "home-pager-viewport")
            .firstMatch
    }

    private func waitForStableFrame(
        _ element: XCUIElement,
        timeout: TimeInterval = 3
    ) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        var previous = element.frame
        var stableSamples = 0

        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            guard element.exists else { return false }
            let current = element.frame
            let stable = abs(current.minX - previous.minX) <= 0.5
                && abs(current.minY - previous.minY) <= 0.5
                && abs(current.width - previous.width) <= 0.5
                && abs(current.height - previous.height) <= 0.5
            if stable {
                stableSamples += 1
                if stableSamples >= 2 { return true }
            } else {
                stableSamples = 0
            }
            previous = current
        }
        return false
    }

    private func assertFullyVisible(
        _ element: XCUIElement,
        in app: XCUIApplication,
        fixture: String,
        viewport: XCUIElement? = nil
    ) {
        XCTAssertTrue(element.isHittable, "fixture \(fixture) control is not hittable")
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, "fixture \(fixture) control lost its 44pt hit target")
        XCTAssertGreaterThanOrEqual(element.frame.width, 44, "fixture \(fixture) control lost its 44pt horizontal hit target")
        // Always bound against the window too (#582 review F4): a viewport
        // element that is itself the overflowing content (a SwiftUI stack
        // reports its full size when it outgrows its proposal) moves WITH
        // the overflow, so the viewport check alone can go vacuous exactly
        // when the screen stops fitting.
        assertNotClipped(element, in: app, fixture: fixture)
        if let viewport {
            assertNotClipped(element, in: viewport, fixture: fixture)
        }
    }

    /// #539 round-1 review F1: the clipping bounds-check half of
    /// `assertFullyVisible`, without the 44pt hit-target requirement — for
    /// non-interactive content (a text line, a state chip) that has no tap
    /// target to protect but must still stay within the viewport.
    private func assertNotClipped(_ element: XCUIElement, in app: XCUIApplication, fixture: String) {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        assertNotClipped(element, in: window, fixture: fixture)
    }

    /// Compare against the actual owner of the content's clipping boundary.
    /// A watch UIWindow includes the bottom system inset, while the page-style
    /// TabView can still clip its child above that edge; using this overload is
    /// what makes the Home regression guard fail for a visually cropped card.
    private func assertNotClipped(_ element: XCUIElement, in viewport: XCUIElement, fixture: String) {
        XCTAssertTrue(viewport.waitForExistence(timeout: 5), "fixture \(fixture) viewport is unavailable")
        let frame = element.frame
        let bounds = viewport.frame
        XCTAssertGreaterThan(bounds.width, 0, "fixture \(fixture) viewport has no width")
        XCTAssertGreaterThan(bounds.height, 0, "fixture \(fixture) viewport has no height")
        XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX, "fixture \(fixture) control is clipped on the left")
        XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX, "fixture \(fixture) control is clipped on the right")
        XCTAssertGreaterThanOrEqual(frame.minY, bounds.minY, "fixture \(fixture) control is clipped above")
        XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY + 0.5, "fixture \(fixture) control is clipped below")
    }

    /// SL-538: the Start button fills with `WatchPalette.primary`
    /// (`WatchDesignTokens.primary`, an indigo/violet blue — not the old
    /// decorative magenta) at ~0.92 fill opacity over the dark canvas, so the
    /// rendered pixel is blue-dominant with a distinctly low green channel
    /// (unlike `secondary`'s cyan, where green tracks blue). Keep this
    /// threshold in sync with `WatchDesignTokens.primary` if that token's
    /// RGB ever changes.
    private func hasPrimaryStartSurface(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return false }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return false }

        var primaryPixels = 0
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            let red = Int(rgba[offset])
            let green = Int(rgba[offset + 1])
            let blue = Int(rgba[offset + 2])
            if blue >= 150, red >= 40,
               blue >= red + 60, blue >= green + 70, green <= red + 40 {
                primaryPixels += 1
            }
        }
        return primaryPixels >= max(512, width * height / 100)
    }

    /// #580: the resting phase band is the rendered-pixel proof for a
    /// retained workout capture. Accessibility can remain current after
    /// watchOS has entered a blank Always-On framebuffer, so a black image
    /// must not be accepted as visual evidence for the compact controls. The
    /// band (`WorkoutPhasePalette`'s resting purple) must form a wide
    /// contiguous surface below the clock, and the rest selector must
    /// contribute cyan pixels (the 2m pill's `WatchDesignTokens.secondary`
    /// text/stroke) so a stray blue pixel elsewhere cannot satisfy this.
    private func hasWorkoutPhaseSurface(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return false }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return false }

        var phasePixels = 0
        var cyanSelectorPixels = 0
        var widestPhaseRow = 0
        var substantialPhaseRows = 0
        let clockRows = max(1, height / 5)
        let bottomRows = min(height, height * 4 / 5)
        for y in clockRows..<bottomRows {
            var phaseRowPixels = 0
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let red = Int(rgba[offset])
                let green = Int(rgba[offset + 1])
                let blue = Int(rgba[offset + 2])
                // The resting band is a broad blue/purple surface. Keep the
                // threshold tolerant of the gradient and Always-On dimming,
                // but require a contiguous band-sized row below.
                if blue >= 55, blue >= red + 35, blue >= green + 12 {
                    phasePixels += 1
                    phaseRowPixels += 1
                }
                if green >= 70, blue >= 70, green >= red + 40, blue >= green - 10 {
                    cyanSelectorPixels += 1
                }
            }
            widestPhaseRow = max(widestPhaseRow, phaseRowPixels)
            if phaseRowPixels >= width * 55 / 100 {
                substantialPhaseRows += 1
            }
        }
        return phasePixels >= max(64, width * height / 2_500)
            && widestPhaseRow >= width * 55 / 100
            && substantialPhaseRows >= max(6, height / 40)
            && cyanSelectorPixels >= 24
    }

    /// #569: prove the retained icon fixture is a rendered app frame, not the
    /// black/AOD framebuffer that can still expose a live accessibility tree.
    /// The selected navigation control uses the shared cyan accent, so require
    /// a bounded count of cyan pixels below the upper clock region. The lower
    /// scan window also keeps system clock text from satisfying the assertion.
    private func hasSelectedIconSurface(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return false }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return false }

        var cyanPixels = 0
        let clockRows = max(1, height / 5)
        for offset in stride(from: clockRows * width * 4, to: rgba.count, by: 4) {
            let red = Int(rgba[offset])
            let green = Int(rgba[offset + 1])
            let blue = Int(rgba[offset + 2])
            if green >= 45, blue >= 55,
               blue >= green + 3, green >= red + 25 {
                cyanPixels += 1
            }
        }
        return cyanPixels >= max(64, width * height / 2_500)
    }

}
