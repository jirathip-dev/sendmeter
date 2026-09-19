import Foundation
import GRDB
import XCTest
@testable import SendmeterCore

/// #964 RED-before-fix probe. At the BASE tree (`origin/staging` at dispatch)
/// every launch-path failure family collapses into `.unknown`; each assertion
/// below fails there. Only base symbols are used, so the file compiles at the
/// base commit and the failure is a behavioural RED, not a compile error.
final class Issue964BaseRedTests: XCTestCase {
    func testLaunchPathFailureFamiliesAreNotTheGenericFallback() {
        let decoding = DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "unexpected payload")
        )
        XCTAssertNotEqual(
            UserFacingError.classification(for: decoding),
            .unknown,
            "a DecodingError must not read as the generic fallback"
        )
        XCTAssertNotEqual(
            UserFacingError.classification(
                for: DatabaseError(resultCode: .SQLITE_CANTOPEN, message: "unable to open database file")
            ),
            .unknown,
            "a GRDB cache-open failure must not read as the generic fallback"
        )
        XCTAssertNotEqual(
            UserFacingError.classification(
                for: NSError(domain: NSOSStatusErrorDomain, code: -25291)
            ),
            .unknown,
            "a Keychain failure must not read as the generic fallback"
        )
        XCTAssertNotEqual(
            UserFacingError.classification(
                for: NSError(domain: "com.apple.healthkit", code: 4)
            ),
            .unknown,
            "a HealthKit failure must not read as the generic fallback"
        )
    }
}
