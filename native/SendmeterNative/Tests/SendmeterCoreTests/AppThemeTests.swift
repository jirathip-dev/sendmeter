import XCTest
@testable import SendmeterCore

final class AppThemeTests: XCTestCase {
    private let suiteName = "AppThemeTests.\(UUID().uuidString)"
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

    func testStoredChoiceDefaultsToSystem() {
        XCTAssertEqual(AppTheme.storedChoice(defaults: defaults), .system)
    }

    func testStoreAndReadRoundTrip() {
        AppTheme.store(.dark, defaults: defaults)
        XCTAssertEqual(AppTheme.storedChoice(defaults: defaults), .dark)
        AppTheme.store(.light, defaults: defaults)
        XCTAssertEqual(AppTheme.storedChoice(defaults: defaults), .light)
        AppTheme.store(.system, defaults: defaults)
        XCTAssertEqual(AppTheme.storedChoice(defaults: defaults), .system)
    }

    func testNormalizeRejectsUnknownValues() {
        XCTAssertEqual(AppTheme.normalize(nil), .system)
        XCTAssertEqual(AppTheme.normalize(""), .system)
        XCTAssertEqual(AppTheme.normalize("System"), .system)
        XCTAssertEqual(AppTheme.normalize("LIGHT"), .system)
        XCTAssertEqual(AppTheme.normalize("light"), .light)
        XCTAssertEqual(AppTheme.normalize("dark"), .dark)
    }

    func testResolvedFollowsSystemWhenChoiceIsSystem() {
        XCTAssertEqual(AppTheme.resolved(choice: .system, prefersDark: false), .light)
        XCTAssertEqual(AppTheme.resolved(choice: .system, prefersDark: true), .dark)
    }

    func testResolvedExplicitChoiceWins() {
        XCTAssertEqual(AppTheme.resolved(choice: .light, prefersDark: true), .light)
        XCTAssertEqual(AppTheme.resolved(choice: .dark, prefersDark: false), .dark)
    }

    func testDisplayNamesMatchWebOptions() {
        XCTAssertEqual(AppThemeChoice.system.displayName, "System")
        XCTAssertEqual(AppThemeChoice.light.displayName, "Light")
        XCTAssertEqual(AppThemeChoice.dark.displayName, "Dark")
    }
}
