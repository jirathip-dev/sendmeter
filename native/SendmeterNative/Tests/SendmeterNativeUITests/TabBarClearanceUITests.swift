import XCTest

/// #1028 F5 + P4 (rollout slice 2, #1031): on the Force tab nothing ends up
/// under the sticky Force bar or the tab bar. At the end of the scroll the
/// last content row is fully visible above both bars, and the Force bar
/// sits above the tab bar. Slice 3 (#1032) adds the same last-row check for
/// Dashboard, Workout, History and Settings (tab bar only).
///
/// Runs on the existing `--tabs-fixture force` harness (the real
/// `MainTabView` without a signed-in session) on an iPhone SE (3rd
/// generation) simulator, the smallest supported viewport (375x667 pt):
///
///   xcodebuild test -scheme SendmeterNative \
///     -destination 'platform=iOS Simulator,name=<an iPhone SE (3rd generation)>' \
///     -only-testing:SendmeterNativeUITests/TabBarClearanceUITests
final class TabBarClearanceUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testForceLastRowIsFullyVisibleAboveTheForceBarAndTabBar() {
        let app = XCUIApplication()
        app.launchArguments = ["--tabs-fixture", "force"]
        app.launch()
        defer { app.terminate() }

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 20), "Force: no tab bar")
        let forceBar = app.otherElements["force-bottom-bar"]
        XCTAssertTrue(forceBar.waitForExistence(timeout: 10), "Force: the sticky bar is missing")
        XCTAssertNotNil(mainScrollContainer(in: app), "Force: no vertical scroll container")

        // Drag to the end of the scroll. Drag inside the middle of the window:
        // a drag that starts on the floating tab bar would switch tabs.
        let window = app.windows.firstMatch
        for _ in 0..<6 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        }
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(
            tabBar.buttons["Force"].isSelected || tabBar.buttons["Force"].value as? String == "1",
            "Force: the drag changed the selected tab"
        )

        XCTAssertGreaterThan(forceBar.frame.height, 44, "Force: bar too short for its controls")
        XCTAssertLessThanOrEqual(
            forceBar.frame.maxY,
            tabBar.frame.minY + 0.5,
            "Force: the sticky bar must sit above the tab bar, not under it"
        )
        let barTop = min(tabBar.frame.minY, forceBar.frame.minY)

        // Snapshot the whole app, not the container (a stale container
        // element can fail to resolve after the drag). The bars' own controls
        // are excluded STRUCTURALLY (their subtrees are skipped), never by
        // geometry: a content row hidden entirely behind the bar is exactly
        // the F5 defect and must count.
        let screen = window.frame
        XCTContext.runActivity(named: "window \(screen.width)x\(screen.height) pt") { _ in }
        let frames: [(label: String, frame: CGRect)]
        do {
            frames = contentFrames(in: try app.snapshot())
        } catch {
            XCTFail("Force: accessibility snapshot failed: \(error.localizedDescription)")
            return
        }
        let rows = frames.filter { row in
            row.frame.width > 0 && row.frame.height > 0
                && row.frame.maxY > screen.minY && row.frame.minY < screen.maxY
        }
        guard let last = rows.max(by: { $0.frame.maxY < $1.frame.maxY }) else {
            XCTFail("Force: no visible content rows")
            return
        }
        XCTContext.runActivity(
            named: "Force: last row \"\(last.label)\" ends at \(last.frame.maxY), bars start at \(barTop)"
        ) { _ in }
        XCTAssertLessThanOrEqual(
            last.frame.maxY,
            barTop + 0.5,
            "Force: the last row \"\(last.label)\" ends at \(last.frame.maxY) under the bars (top \(barTop))"
        )
    }

    func testDashboardLastRowIsFullyVisibleAboveTheTabBar() {
        assertLastRowClearsTheTabBar(fixture: "dashboard", tab: "Dashboard")
    }

    func testWorkoutLastRowIsFullyVisibleAboveTheTabBar() {
        assertLastRowClearsTheTabBar(fixture: "workout", tab: "Workout")
    }

    func testHistoryLastRowIsFullyVisibleAboveTheTabBar() {
        assertLastRowClearsTheTabBar(fixture: "history", tab: "History")
    }

    func testSettingsLastRowIsFullyVisibleAboveTheTabBar() {
        assertLastRowClearsTheTabBar(fixture: "settings", tab: "Settings")
    }

    /// #1032 F5: the Force contract above for a tab without the sticky bar —
    /// at the end of the scroll the last content row ends above the tab bar.
    private func assertLastRowClearsTheTabBar(fixture: String, tab: String) {
        let app = XCUIApplication()
        app.launchArguments = ["--tabs-fixture", fixture]
        app.launch()
        defer { app.terminate() }

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 20), "\(tab): no tab bar")
        XCTAssertTrue(tabBar.buttons[tab].waitForExistence(timeout: 10), "\(tab): no tab button")
        XCTAssertFalse(app.otherElements["force-bottom-bar"].exists, "\(tab): the Force bar belongs to Force only")
        XCTAssertNotNil(mainScrollContainer(in: app), "\(tab): no vertical scroll container")

        // Drag to the end of the scroll, inside the middle of the window (a
        // drag that starts on the floating tab bar would switch tabs).
        let window = app.windows.firstMatch
        for _ in 0..<10 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        }
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(
            tabBar.buttons[tab].isSelected || tabBar.buttons[tab].value as? String == "1",
            "\(tab): the drag changed the selected tab"
        )

        let barTop = tabBar.frame.minY
        let screen = window.frame
        XCTContext.runActivity(named: "window \(screen.width)x\(screen.height) pt") { _ in }
        let frames: [(label: String, frame: CGRect)]
        do {
            frames = contentFrames(in: try app.snapshot())
        } catch {
            XCTFail("\(tab): accessibility snapshot failed: \(error.localizedDescription)")
            return
        }
        let rows = frames.filter { row in
            row.frame.width > 0 && row.frame.height > 0
                && row.frame.maxY > screen.minY && row.frame.minY < screen.maxY
        }
        guard let last = rows.max(by: { $0.frame.maxY < $1.frame.maxY }) else {
            XCTFail("\(tab): no visible content rows")
            return
        }
        XCTContext.runActivity(
            named: "\(tab): last row \"\(last.label)\" ends at \(last.frame.maxY), tab bar starts at \(barTop)"
        ) { _ in }
        XCTAssertLessThanOrEqual(
            last.frame.maxY,
            barTop + 0.5,
            "\(tab): the last row \"\(last.label)\" ends at \(last.frame.maxY) under the tab bar (top \(barTop))"
        )
    }

    /// The tab's main vertical scroller, whichever covers most of the window.
    private func mainScrollContainer(in app: XCUIApplication) -> XCUIElement? {
        let window = app.windows.firstMatch.frame
        let candidates = [app.scrollViews.firstMatch, app.collectionViews.firstMatch, app.tables.firstMatch]
        return candidates
            .filter { $0.exists && $0.frame.height > window.height * 0.4 }
            .max { $0.frame.height < $1.frame.height }
    }

    private static let rowKinds: Set<XCUIElement.ElementType> = [.staticText, .button, .cell, .image, .switch, .textField]

    /// Every content element's frame, skipping the two bars' subtrees (the
    /// tab bar and the sticky Force bar), so their controls are not rows.
    private func contentFrames(in snapshot: XCUIElementSnapshot) -> [(label: String, frame: CGRect)] {
        var result: [(String, CGRect)] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.elementType == .tabBar || node.identifier == "force-bottom-bar" { return }
            if Self.rowKinds.contains(node.elementType) {
                result.append((name(label: node.label, identifier: node.identifier, kind: node.elementType), node.frame))
            }
            node.children.forEach(walk)
        }
        snapshot.children.forEach(walk)
        return result
    }

    private func name(label: String, identifier: String, kind: XCUIElement.ElementType) -> String {
        if !label.isEmpty { return label }
        return identifier.isEmpty ? "element type \(kind.rawValue)" : identifier
    }
}
