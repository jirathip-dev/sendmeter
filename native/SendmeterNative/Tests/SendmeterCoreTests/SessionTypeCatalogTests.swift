import XCTest
@testable import SendmeterCore

final class SessionTypeCatalogTests: XCTestCase {
    func testUnknownTypeUsesCustomFallbackWithoutDependingOnCatalogLookup() {
        let definition = SessionTypeCatalog.definition(for: "future-backend-type")

        XCTAssertEqual(definition.id, "custom")
        XCTAssertEqual(definition.label, "Custom")
        XCTAssertEqual(definition.defaultRPE, 6)
        XCTAssertEqual(definition.defaultDurationMinutes, 60)
    }
}
