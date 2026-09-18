import XCTest

/// #927: the interaction half of the shared error banner's accessibility
/// contract — the lane's app-target tests cannot press a SwiftUI control, so
/// this UI test drives the REAL banner end to end on a simulator:
///
/// - launches the app with the DEBUG `--error-banner-fixture short|long`
///   harness (the same `ErrorBanner` the app presents, over the signed-out
///   screen),
/// - finds the dismiss control by its `error-banner-dismiss` accessibility
///   identifier and checks what the assistive layer sees (label, target size,
///   hittability),
/// - taps it and asserts the banner leaves the screen.
///
/// This bundle is not wired into any workflow (see the lane report); it is run
/// by hand with `-only-testing:SendmeterNativeUITests` on a booted simulator.
final class ErrorBannerDismissUITests: XCTestCase {
    private enum Fixture: String {
        case short
        case long
    }

    func testTappingDismissRemovesShortErrorBanner() {
        assertDismissRemovesBanner(fixture: .short)
    }

    func testTappingDismissRemovesLongErrorBanner() {
        assertDismissRemovesBanner(fixture: .long, expectWrappedMessage: true)
    }

    private func assertDismissRemovesBanner(
        fixture: Fixture,
        expectWrappedMessage: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let app = XCUIApplication()
        app.launchArguments = ["--error-banner-fixture", fixture.rawValue]
        app.launch()
        defer { app.terminate() }

        let dismiss = app.buttons["error-banner-dismiss"]
        XCTAssertTrue(
            dismiss.waitForExistence(timeout: 30),
            "the banner's dismiss control did not appear",
            file: file,
            line: line
        )

        // What the assistive layer sees on a real device screen.
        XCTAssertEqual(
            dismiss.label,
            "Dismiss error",
            "the dismiss control must carry its explicit user-facing label",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            dismiss.frame.width,
            44,
            "the dismiss target must be at least 44 pt wide",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            dismiss.frame.height,
            44,
            "the dismiss target must be at least 44 pt tall",
            file: file,
            line: line
        )
        XCTAssertTrue(
            dismiss.isHittable,
            "the dismiss target must be reachable (no decorative layer over it)",
            file: file,
            line: line
        )

        let message = app.staticTexts["error-banner-message"]
        XCTAssertTrue(
            message.exists,
            "the banner message must be on screen",
            file: file,
            line: line
        )
        if expectWrappedMessage {
            // The rendered message element's height proves it wrapped on
            // screen (a single subheadline line on this phone is ~20 pt).
            XCTAssertGreaterThanOrEqual(
                message.frame.height,
                60,
                "the long error must wrap to multiple lines on screen",
                file: file,
                line: line
            )
        }

        dismiss.tap()

        XCTAssertTrue(
            dismiss.waitForNonExistence(timeout: 10),
            "tapping dismiss must remove the banner",
            file: file,
            line: line
        )
        XCTAssertFalse(
            message.exists,
            "the banner message must go with it",
            file: file,
            line: line
        )
    }
}
