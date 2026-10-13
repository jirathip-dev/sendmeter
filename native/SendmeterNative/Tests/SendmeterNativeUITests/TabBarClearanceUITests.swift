import XCTest

/// #1028 F5: every tab leaves bottom room for the tab bar — plus the Force
/// tab's sticky bar — so at the end of the scroll the last row is fully
/// visible above both bars (nothing ends up underneath either).
///
/// Runs on the DEBUG design harness (`--design-1028 <state>`: the real
/// `MainTabView` over seeded data) and is meant for an SE-size simulator,
/// the smallest supported viewport:
///
///   xcodebuild test -scheme SendmeterNative \
///     -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' \
///     -only-testing:SendmeterNativeUITests/TabBarClearanceUITests
final class TabBarClearanceUITests: XCTestCase {
    private let tabs: [(state: String, name: String, hasForceBar: Bool)] = [
        ("dashboard", "Dashboard", false),
        ("force-guided-armed", "Force", true),
        ("workout", "Workout", false),
        ("history", "History", false),
        ("settings", "Settings", false),
    ]

    override func setUp() {
        continueAfterFailure = true
    }

    func testLastRowIsFullyVisibleAboveTheBarsOnEveryTab() {
        for tab in tabs {
            XCTContext.runActivity(named: "\(tab.name) tab") { _ in
                let app = XCUIApplication()
                app.launchArguments = ["--design-1028", tab.state, "--design-1028-scroll", "bottom"]
                app.launch()
                defer { app.terminate() }

                let tabBar = app.tabBars.firstMatch
                XCTAssertTrue(tabBar.waitForExistence(timeout: 15), "\(tab.name): no tab bar")
                let forceBar = app.otherElements["force-bottom-bar"]
                if tab.hasForceBar {
                    XCTAssertTrue(forceBar.waitForExistence(timeout: 10), "Force: the sticky bar is missing")
                }

                // The harness scrolls the tab's main scroll view to its end
                // at 1.0/1.8/2.6 s.
                Thread.sleep(forTimeInterval: 3.2)
                XCTAssertNotNil(mainScrollContainer(in: app), "\(tab.name): no vertical scroll container")
                // A real drag proves the end. Drag inside the middle of the
                // window: an element-relative swipeUp on a List whose frame
                // runs to the screen edge can start on the floating tab bar
                // (dragging its selection lens to another tab).
                let window0 = app.windows.firstMatch
                window0.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
                    .press(forDuration: 0.05, thenDragTo: window0.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
                Thread.sleep(forTimeInterval: 1.5)
                XCTAssertTrue(
                    tabBar.buttons[tab.name].isSelected || tabBar.buttons[tab.name].value as? String == "1",
                    "\(tab.name): the drag changed the selected tab"
                )

                var barTop = tabBar.frame.minY
                if tab.hasForceBar, forceBar.exists {
                    barTop = min(barTop, forceBar.frame.minY)
                    XCTAssertGreaterThan(forceBar.frame.height, 44, "Force: bar too short for its controls")
                    XCTAssertLessThanOrEqual(
                        forceBar.frame.maxY,
                        tabBar.frame.minY + 0.5,
                        "Force: the sticky bar must sit above the tab bar, not under it"
                    )
                } else {
                    XCTAssertFalse(forceBar.exists, "\(tab.name): the Force bar belongs to Force only")
                }

                // Snapshot the whole app, not the container: a List's
                // collection view can be re-created by the drag, and the
                // stale element then fails to resolve. If the snapshot
                // fails, query the visible elements instead. The filter
                // below keeps on-screen rows and drops the bars' own
                // controls.
                let frames: [(label: String, frame: CGRect)]
                do {
                    frames = contentFrames(in: try app.snapshot())
                } catch {
                    XCTContext.runActivity(named: "\(tab.name): snapshot failed (\(error.localizedDescription)) — querying elements") { _ in }
                    frames = queriedFrames(in: app)
                }
                let window = app.windows.firstMatch.frame
                let bars = [tabBar.frame] + (tab.hasForceBar && forceBar.exists ? [forceBar.frame] : [])
                let rows = frames.filter { row in
                    row.frame.width > 0 && row.frame.height > 0
                        && row.frame.maxY > window.minY && row.frame.minY < window.maxY
                        // the bars' own controls are not content
                        && !bars.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(row.frame) })
                }
                guard let last = rows.max(by: { $0.frame.maxY < $1.frame.maxY }) else {
                    XCTFail("\(tab.name): no visible content rows")
                    return
                }
                XCTContext.runActivity(
                    named: "\(tab.name): last row \"\(last.label)\" ends at \(last.frame.maxY), bars start at \(barTop)"
                ) { _ in }
                XCTAssertLessThanOrEqual(
                    last.frame.maxY,
                    barTop + 0.5,
                    "\(tab.name): the last row \"\(last.label)\" ends at \(last.frame.maxY) under the bars (top \(barTop))"
                )
            }
        }
    }

    /// The tab's main vertical scroller: a List (collection view / table)
    /// or a ScrollView, whichever covers most of the window.
    private func mainScrollContainer(in app: XCUIApplication) -> XCUIElement? {
        let window = app.windows.firstMatch.frame
        let candidates = [app.collectionViews.firstMatch, app.tables.firstMatch, app.scrollViews.firstMatch]
        return candidates
            .filter { $0.exists && $0.frame.height > window.height * 0.4 }
            .max { $0.frame.height < $1.frame.height }
    }

    private static let rowKinds: [XCUIElement.ElementType] = [.staticText, .button, .cell, .image, .switch, .textField]

    private func queriedFrames(in container: XCUIApplication) -> [(label: String, frame: CGRect)] {
        var result: [(String, CGRect)] = []
        for kind in Self.rowKinds {
            let query = container.descendants(matching: kind)
            for index in 0..<min(query.count, 150) {
                let element = query.element(boundBy: index)
                guard element.exists else { continue }
                let name = element.label.isEmpty ? (element.identifier.isEmpty ? "element type \(kind.rawValue)" : element.identifier) : element.label
                result.append((name, element.frame))
            }
        }
        return result
    }

    private func contentFrames(in snapshot: XCUIElementSnapshot) -> [(label: String, frame: CGRect)] {
        var result: [(String, CGRect)] = []
        let kinds = Set(Self.rowKinds)
        func walk(_ node: XCUIElementSnapshot) {
            if kinds.contains(node.elementType) {
                let name = node.label.isEmpty ? (node.identifier.isEmpty ? "element type \(node.elementType.rawValue)" : node.identifier) : node.label
                result.append((name, node.frame))
            }
            node.children.forEach(walk)
        }
        snapshot.children.forEach(walk)
        return result
    }
}
