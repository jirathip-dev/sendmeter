import Foundation
import XCTest
@testable import SendmeterCore

/// #842: the surface() classification matrix. A background/partial refresh
/// failure must not produce the global offline banner while a last-good
/// dataset is visible; a genuine total-offline cold start (user-initiated,
/// or background with no data) still does.
final class ErrorSurfacePolicyTests: XCTestCase {
    private let policy = ErrorSurfacePolicy()

    func testUserInitiatedFailureAlwaysSurfaces() {
        XCTAssertTrue(policy.shouldSurface(source: .userInitiated, hasLastGoodData: false))
        XCTAssertTrue(policy.shouldSurface(source: .userInitiated, hasLastGoodData: true))
    }

    func testBackgroundFailureWithLastGoodDataIsSuppressed() {
        XCTAssertFalse(policy.shouldSurface(source: .background, hasLastGoodData: true))
    }

    func testBackgroundFailureWithoutLastGoodDataStillSurfaces() {
        XCTAssertTrue(policy.shouldSurface(source: .background, hasLastGoodData: false))
    }
}
