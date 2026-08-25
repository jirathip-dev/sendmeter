import XCTest
@testable import SendmeterCore

/// Pins the per-exercise side-mode policy — a port of `src/lib/sideMode.test.ts`
/// (web #584). The default/legacy behavior and the `""`/`both` distinction are
/// the load-bearing contracts: an unconfigured exercise must keep offering every
/// side, and an empty side must never be reinterpreted as `both`.
final class ExerciseSideModeTests: XCTestCase {
    private let allModes: [ExerciseSideMode] = [
        .unilateralOrBilateral,
        .unilateralOnly,
        .bilateralOnly,
        .notApplicable,
    ]

    private let allSides: [TindeqSide] = [.unspecified, .left, .right, .both]

    // MARK: allowedSides

    func testAllowedSidesPolicyTableForAllModes() {
        XCTAssertEqual(
            ExerciseSidePolicy.allowedSides(.unilateralOrBilateral),
            [.unspecified, .left, .right, .both]
        )
        XCTAssertEqual(
            ExerciseSidePolicy.allowedSides(.unilateralOnly),
            [.unspecified, .left, .right]
        )
        XCTAssertEqual(
            ExerciseSidePolicy.allowedSides(.bilateralOnly),
            [.unspecified, .both]
        )
        XCTAssertEqual(
            ExerciseSidePolicy.allowedSides(.notApplicable),
            [.unspecified]
        )
    }

    func testAllowedSidesAlwaysIncludesUnspecified() {
        for mode in allModes {
            XCTAssertTrue(ExerciseSidePolicy.allowedSides(mode).contains(.unspecified))
        }
    }

    // MARK: isSideAllowed

    func testIsSideAllowedMatchesAllowedSides() {
        for mode in allModes {
            for side in allSides {
                XCTAssertEqual(
                    ExerciseSidePolicy.isSideAllowed(mode, side),
                    ExerciseSidePolicy.allowedSides(mode).contains(side),
                    "mode \(mode) side \(side)"
                )
            }
        }
    }

    func testIsSideAllowedNeverTreatsUnspecifiedAsBoth() {
        XCTAssertTrue(ExerciseSidePolicy.isSideAllowed(.bilateralOnly, .unspecified))
        XCTAssertTrue(ExerciseSidePolicy.isSideAllowed(.bilateralOnly, .both))
        XCTAssertFalse(ExerciseSidePolicy.isSideAllowed(.notApplicable, .both))
        XCTAssertTrue(ExerciseSidePolicy.isSideAllowed(.notApplicable, .unspecified))
    }

    // MARK: normalizeSide

    func testNormalizeSideKeepsValidSideUnchanged() {
        XCTAssertEqual(ExerciseSidePolicy.normalizeSide(.unilateralOrBilateral, .left), .left)
        XCTAssertEqual(ExerciseSidePolicy.normalizeSide(.unilateralOrBilateral, .both), .both)
        XCTAssertEqual(ExerciseSidePolicy.normalizeSide(.unilateralOrBilateral, .unspecified), .unspecified)
        XCTAssertEqual(ExerciseSidePolicy.normalizeSide(.unilateralOnly, .right), .right)
        XCTAssertEqual(ExerciseSidePolicy.normalizeSide(.bilateralOnly, .both), .both)
        XCTAssertEqual(ExerciseSidePolicy.normalizeSide(.notApplicable, .unspecified), .unspecified)
    }

    func testNormalizeSideBilateralFallsBackToBoth() {
        XCTAssertEqual(ExerciseSidePolicy.normalizeSide(.bilateralOnly, .left), .both)
        XCTAssertEqual(ExerciseSidePolicy.normalizeSide(.bilateralOnly, .right), .both)
    }

    func testNormalizeSideNotApplicableFallsBackToUnspecified() {
        XCTAssertEqual(ExerciseSidePolicy.normalizeSide(.notApplicable, .left), .unspecified)
        XCTAssertEqual(ExerciseSidePolicy.normalizeSide(.notApplicable, .right), .unspecified)
        XCTAssertEqual(ExerciseSidePolicy.normalizeSide(.notApplicable, .both), .unspecified)
    }

    func testNormalizeSideUnilateralFallsBackToUnspecifiedForAmbiguousBoth() {
        XCTAssertEqual(ExerciseSidePolicy.normalizeSide(.unilateralOnly, .both), .unspecified)
    }

    func testNormalizeSideNeverReinterpretsHistoricalEmptyAsBoth() {
        for mode in allModes {
            XCTAssertEqual(ExerciseSidePolicy.normalizeSide(mode, .unspecified), .unspecified)
        }
    }

    // MARK: normalizeSideMode (ExerciseSideMode.normalize)

    func testNormalizeSideModePassesThroughEveryKnownMode() {
        for mode in allModes {
            XCTAssertEqual(ExerciseSideMode.normalize(mode.rawValue), mode)
        }
    }

    func testNormalizeSideModeDefaultsUnknownToUnilateralOrBilateral() {
        XCTAssertEqual(ExerciseSideMode.normalize("some_future_mode"), .unilateralOrBilateral)
        XCTAssertEqual(ExerciseSideMode.normalize(""), .unilateralOrBilateral)
    }

    func testNormalizeSideModeDefaultsMissingRegistryRowToUnilateralOrBilateral() {
        XCTAssertEqual(ExerciseSideMode.normalize(nil), .unilateralOrBilateral)
        XCTAssertEqual(ExerciseSideMode.defaultMode, .unilateralOrBilateral)
    }

    // MARK: recordedSide (save-time canonical side)

    func testRecordedSideBilateralIsAlwaysBoth() {
        XCTAssertEqual(ExerciseSidePolicy.recordedSide(.bilateralOnly, .unspecified), .both)
        XCTAssertEqual(ExerciseSidePolicy.recordedSide(.bilateralOnly, .both), .both)
        XCTAssertEqual(ExerciseSidePolicy.recordedSide(.bilateralOnly, .left), .both)
        XCTAssertEqual(ExerciseSidePolicy.recordedSide(.bilateralOnly, .right), .both)
    }

    func testRecordedSideNotApplicableIsAlwaysUnspecified() {
        XCTAssertEqual(ExerciseSidePolicy.recordedSide(.notApplicable, .unspecified), .unspecified)
        XCTAssertEqual(ExerciseSidePolicy.recordedSide(.notApplicable, .left), .unspecified)
        XCTAssertEqual(ExerciseSidePolicy.recordedSide(.notApplicable, .both), .unspecified)
    }

    func testRecordedSideKeepsValidUnilateralSide() {
        XCTAssertEqual(ExerciseSidePolicy.recordedSide(.unilateralOnly, .left), .left)
        XCTAssertEqual(ExerciseSidePolicy.recordedSide(.unilateralOnly, .right), .right)
        XCTAssertEqual(ExerciseSidePolicy.recordedSide(.unilateralOnly, .unspecified), .unspecified)
        XCTAssertEqual(ExerciseSidePolicy.recordedSide(.unilateralOrBilateral, .left), .left)
        XCTAssertEqual(ExerciseSidePolicy.recordedSide(.unilateralOrBilateral, .both), .both)
    }

    /// Regression for the hands-free blocker (#720 review): the *effective*
    /// side (`recordedSide`) changes when the exercise's side mode changes even
    /// while the raw `side` stays `.unspecified` — so the free-pull context must
    /// be re-published on `recordedSide`, never just on `side`.
    func testRecordedSideChangesWithModeWhileSideStaysUnspecified() {
        let side = TindeqSide.unspecified
        XCTAssertEqual(ExerciseSidePolicy.recordedSide(.bilateralOnly, side), .both)
        XCTAssertEqual(ExerciseSidePolicy.recordedSide(.notApplicable, side), .unspecified)
    }

    // MARK: TagSideModeStore (device-local persistence)

    private let suiteName = "ExerciseSideModeTests.\(UUID().uuidString)"
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

    func testStoredModeDefaultsToUnilateralOrBilateral() {
        XCTAssertEqual(TagSideModeStore.storedMode(for: "half crimp", defaults: defaults), .unilateralOrBilateral)
    }

    func testStoreAndReadRoundTrip() {
        TagSideModeStore.store(.bilateralOnly, for: "half crimp", defaults: defaults)
        XCTAssertEqual(TagSideModeStore.storedMode(for: "half crimp", defaults: defaults), .bilateralOnly)
        TagSideModeStore.store(.notApplicable, for: "sloper", defaults: defaults)
        XCTAssertEqual(TagSideModeStore.storedMode(for: "sloper", defaults: defaults), .notApplicable)
    }

    func testStoreDefaultsUnknownValue() {
        defaults.set("some_future_mode", forKey: TagSideModeStore.storageKey(for: "half crimp"))
        XCTAssertEqual(TagSideModeStore.storedMode(for: "half crimp", defaults: defaults), .unilateralOrBilateral)
    }

    func testAllStoredModesCollectsConfiguredTags() {
        TagSideModeStore.store(.bilateralOnly, for: "half crimp", defaults: defaults)
        TagSideModeStore.store(.unilateralOnly, for: "sloper", defaults: defaults)
        TagSideModeStore.store(.notApplicable, for: "pinch", defaults: defaults)
        let modes = TagSideModeStore.allStoredModes(defaults: defaults)
        XCTAssertEqual(modes["half crimp"], .bilateralOnly)
        XCTAssertEqual(modes["sloper"], .unilateralOnly)
        XCTAssertEqual(modes["pinch"], .notApplicable)
        XCTAssertNil(modes["unconfigured"])
    }

    func testRemoveClearsStoredMode() {
        TagSideModeStore.store(.bilateralOnly, for: "half crimp", defaults: defaults)
        TagSideModeStore.remove(for: "half crimp", defaults: defaults)
        XCTAssertEqual(TagSideModeStore.storedMode(for: "half crimp", defaults: defaults), .unilateralOrBilateral)
    }
}
