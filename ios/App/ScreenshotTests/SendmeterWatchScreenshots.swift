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

        let exercise = app.buttons["force-exercise-picker"]
        let side = app.buttons["force-side-picker"]
        let protocolChange = app.buttons
            .matching(NSPredicate(format: "label == %@", "Selected protocol, Movement Starter"))
            .firstMatch
        let start = app.buttons
            .matching(NSPredicate(format: "label == %@", "Start selected protocol"))
            .firstMatch

        let controls = [exercise, side, protocolChange, start]
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
                // #539: the primary readiness card must fit un-cropped in the
                // first viewport on 40/41mm and Ultra — this is the
                // regression guard for the clipping bug, independent of the
                // curated App Store screenshots. `readiness-ring` sits near
                // the card's bottom edge, so an un-clipped ring is a reliable
                // proxy for an un-clipped card without needing a container-
                // level identifier (one was tried and swallowed the ring's
                // own identifier from the accessibility tree — SwiftUI
                // collapses a tagged container's children into one opaque
                // element).
                assertFullyVisible(readiness, in: app, fixture: item.fixture)
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
                for _ in 0..<4 where !exercise.isHittable || !side.isHittable {
                    app.swipeUp(velocity: .slow)
                }
                assertFullyVisible(exercise, in: app, fixture: item.fixture)
                assertFullyVisible(side, in: app, fixture: item.fixture)
            }
            if item.fixture == "forceConnected" {
                let finish = app.buttons["force-session-finish"]
                let exercise = app.buttons["force-exercise-picker"]
                let side = app.buttons["force-side-picker"]
                // watchOS can drop a Button's identifier when ViewThatFits
                // selects a fallback branch, while retaining its production
                // accessibility label. Accept either semantic path.
                let disconnect = app.buttons
                    .matching(
                        NSPredicate(
                            format: "identifier == %@ OR label == %@",
                            "disconnect-progressor",
                            "Disconnect Progressor"
                        )
                    )
                    .firstMatch
                for control in [finish, exercise, side] {
                    XCTAssertTrue(
                        control.waitForExistence(timeout: 5),
                        "fixture \(item.fixture) should expose \(control.identifier)"
                    )
                }
                // The fixture starts at the session row, then proves the
                // setup controls remain reachable through the narrow 40mm
                // layout. Exercise/Side and the secondary disconnect action
                // occupy intentionally different scroll positions, so prove
                // each position independently. The same assertions run on
                // Ultra.
                assertFullyVisible(finish, in: app, fixture: item.fixture)
                for _ in 0..<4 where !exercise.isHittable || !side.isHittable {
                    app.swipeUp(velocity: .slow)
                }
                assertFullyVisible(exercise, in: app, fixture: item.fixture)
                assertFullyVisible(side, in: app, fixture: item.fixture)
                // SwiftUI does not instantiate the micro layout's secondary
                // controls until their scroll region approaches the viewport.
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

        let protocolLink = app.buttons
            .matching(NSPredicate(format: "label == %@", "Selected protocol, Movement Starter"))
            .firstMatch
        XCTAssertTrue(
            protocolLink.waitForExistence(timeout: 10),
            "setup should expose the selected-protocol link before opening the chooser"
        )
        protocolLink.tap()

        let suggestedRow = app.buttons["force-protocol-suggested:movement-starter"]
        XCTAssertTrue(
            suggestedRow.waitForExistence(timeout: 10),
            "chooser should list the Suggested Movement Starter protocol"
        )
        // The row's existence (asserted above) is the coverage this test
        // exists for — it is the regression signal a reverted/broken chooser
        // would fail on. Bringing it fully into frame is presentation
        // niceness for the attached screenshot only: watchOS ScrollView
        // gestures in this simulator have proven bistable and unpredictable
        // (a small drag and a full swipe both landed on the same two
        // far-apart rest positions in manual testing), so scrolling here is
        // best-effort and not asserted on.
        app.swipeUp(velocity: .slow)

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
