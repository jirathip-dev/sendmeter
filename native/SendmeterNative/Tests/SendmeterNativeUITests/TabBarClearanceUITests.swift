import XCTest

/// #1028 F5 + P4 (rollout slice 2, #1031): on the Force tab nothing ends up
/// under the sticky Force bar or the tab bar. At the end of the scroll the
/// last content row is fully visible above both bars, and the Force bar
/// sits above the tab bar. Every-tab clearance is slice 3 (#1032).
///
/// Runs on the existing `--tabs-fixture force` harness (the real
/// `MainTabView` without a signed-in session) and is meant for an SE-size
/// simulator, the smallest supported viewport:
///
///   xcodebuild test -scheme SendmeterNative \
///     -destination 'platform=iOS Simulator,name=<iPhone SE (3rd generation) simulator>' \
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
        // element can fail to resolve after the drag); fall back to element
        // queries if the snapshot fails. The filter keeps on-screen rows and
        // drops the bars' own controls.
        let frames: [(label: String, frame: CGRect)]
        do {
            frames = contentFrames(in: try app.snapshot())
        } catch {
            XCTContext.runActivity(named: "snapshot failed (\(error.localizedDescription)) — querying elements") { _ in }
            frames = queriedFrames(in: app)
        }
        let screen = window.frame
        let bars = [tabBar.frame, forceBar.frame]
        let rows = frames.filter { row in
            row.frame.width > 0 && row.frame.height > 0
                && row.frame.maxY > screen.minY && row.frame.minY < screen.maxY
                && !bars.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(row.frame) })
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

    /// The tab's main vertical scroller, whichever covers most of the window.
    private func mainScrollContainer(in app: XCUIApplication) -> XCUIElement? {
        let window = app.windows.firstMatch.frame
        let candidates = [app.scrollViews.firstMatch, app.collectionViews.firstMatch, app.tables.firstMatch]
        return candidates
            .filter { $0.exists && $0.frame.height > window.height * 0.4 }
            .max { $0.frame.height < $1.frame.height }
    }

    private static let rowKinds: [XCUIElement.ElementType] = [.staticText, .button, .cell, .image, .switch, .textField]

    private func queriedFrames(in app: XCUIApplication) -> [(label: String, frame: CGRect)] {
        var result: [(String, CGRect)] = []
        for kind in Self.rowKinds {
            let query = app.descendants(matching: kind)
            for index in 0..<min(query.count, 150) {
                let element = query.element(boundBy: index)
                guard element.exists else { continue }
                result.append((name(label: element.label, identifier: element.identifier, kind: kind), element.frame))
            }
        }
        return result
    }

    private func contentFrames(in snapshot: XCUIElementSnapshot) -> [(label: String, frame: CGRect)] {
        var result: [(String, CGRect)] = []
        let kinds = Set(Self.rowKinds)
        func walk(_ node: XCUIElementSnapshot) {
            if kinds.contains(node.elementType) {
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
