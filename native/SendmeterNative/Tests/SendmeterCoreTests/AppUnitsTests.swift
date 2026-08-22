import XCTest
@testable import SendmeterCore

final class AppUnitsTests: XCTestCase {
    private let suiteName = "AppUnitsTests.\(UUID().uuidString)"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testStoredChoiceDefaultsToMetric() {
        XCTAssertEqual(AppUnits.storedChoice(defaults: defaults), .metric)
    }

    func testStoreAndReadRoundTrip() {
        AppUnits.store(.imperial, defaults: defaults)
        XCTAssertEqual(AppUnits.storedChoice(defaults: defaults), .imperial)
        AppUnits.store(.metric, defaults: defaults)
        XCTAssertEqual(AppUnits.storedChoice(defaults: defaults), .metric)
    }

    func testNormalizeRejectsUnknownValues() {
        XCTAssertEqual(AppUnits.normalize(nil), .metric)
        XCTAssertEqual(AppUnits.normalize(""), .metric)
        XCTAssertEqual(AppUnits.normalize("Metric"), .metric)
        XCTAssertEqual(AppUnits.normalize("IMPERIAL"), .metric)
        XCTAssertEqual(AppUnits.normalize("imperial"), .imperial)
        XCTAssertEqual(AppUnits.normalize("metric"), .metric)
    }

    func testDisplayNames() {
        XCTAssertEqual(UnitsPreference.metric.displayName, "Metric")
        XCTAssertEqual(UnitsPreference.imperial.displayName, "Imperial")
    }
}
