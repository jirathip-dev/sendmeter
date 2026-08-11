import XCTest
import CoreGraphics
import ImageIO
import UIKit

private enum ForceScreenshotCaptureError: Error {
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

        let readinessRing = app.descendants(matching: .any)
            .matching(identifier: "readiness-ring").firstMatch
        XCTAssertTrue(readinessRing.waitForExistence(timeout: 10))
        assertFullyVisible(readinessRing, in: app, fixture: "status-ax-large")

        let syncLabel = app.descendants(matching: .any)
            .matching(identifier: "status-sync-label").firstMatch
        XCTAssertTrue(syncLabel.waitForExistence(timeout: 5))
        assertNotClipped(syncLabel, in: app, fixture: "status-ax-large")

        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "40mm-status-accessibility-large"
        capture.lifetime = .keepAlways
        add(capture)
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
        app.staticTexts["Force Gauge"].tap()

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
                statusPage.tap()
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
                assertFullyVisible(readinessRing, in: app, fixture: item.fixture)
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
                    assertNotClipped(guidance, in: app, fixture: item.fixture)
                    let capture = XCTAttachment(screenshot: app.screenshot())
                    capture.name = "\(item.fixture)-guidance"
                    capture.lifetime = .keepAlways
                    add(capture)
                } else {
                    let syncLabel = app.descendants(matching: .any)
                        .matching(identifier: "status-sync-label").firstMatch
                    XCTAssertTrue(syncLabel.waitForExistence(timeout: 5), "fixture \(item.fixture) should expose status-sync-label")
                    assertNotClipped(syncLabel, in: app, fixture: item.fixture)
                }
                // #539 round-1 review F3: the state chip (shares a row with
                // the eyebrow now) must stay fully within the card even at
                // its longest real titles, not merely present. Not a tap
                // target, so no 44pt hit-target requirement — `assertNotClipped`,
                // not `assertFullyVisible`.
                let chip = app.descendants(matching: .any)
                    .matching(identifier: item.identifier).firstMatch
                assertNotClipped(chip, in: app, fixture: item.fixture)
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
            app.staticTexts["Force Gauge"].tap()
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
        app.staticTexts["Force Gauge"].tap()

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
        for _ in 0..<20 {
            if suggestedRow.exists {
                let frame = suggestedRow.frame
                if suggestedRow.isHittable,
                   frame.minY >= viewport.minY,
                   frame.maxY <= viewport.maxY {
                    break
                }
                if frame.minY < viewport.minY {
                    // The small reverse nudge recovers from watchOS snapping
                    // the lazy row above the viewport after an upward drag.
                    let dragStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
                    let dragEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.50))
                    dragStart.press(forDuration: 0.1, thenDragTo: dragEnd)
                    continue
                }
            }
            // Full watch swipes can jump past a LazyVStack row entirely. A
            // bounded upward drag advances the chooser by ~20pt until the
            // lazy row materializes and reaches the viewport.
            let dragStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            let dragEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            dragStart.press(forDuration: 0.1, thenDragTo: dragEnd)
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
        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["Force Gauge"].waitForExistence(timeout: 10))
    }

    private func assertFullyVisible(_ element: XCUIElement, in app: XCUIApplication, fixture: String) {
        XCTAssertTrue(element.isHittable, "fixture \(fixture) control is not hittable")
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, "fixture \(fixture) control lost its 44pt hit target")
        XCTAssertGreaterThanOrEqual(element.frame.width, 44, "fixture \(fixture) control lost its 44pt horizontal hit target")
        assertNotClipped(element, in: app, fixture: fixture)
    }

    /// #539 round-1 review F1: the clipping bounds-check half of
    /// `assertFullyVisible`, without the 44pt hit-target requirement — for
    /// non-interactive content (a text line, a state chip) that has no tap
    /// target to protect but must still stay within the viewport.
    private func assertNotClipped(_ element: XCUIElement, in app: XCUIApplication, fixture: String) {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let frame = element.frame
        let bounds = window.frame
        XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX, "fixture \(fixture) control is clipped on the left")
        XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX, "fixture \(fixture) control is clipped on the right")
        XCTAssertGreaterThanOrEqual(frame.minY, bounds.minY, "fixture \(fixture) control is clipped above")
        XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY, "fixture \(fixture) control is clipped below")
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

}
