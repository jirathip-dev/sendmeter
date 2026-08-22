import XCTest
@testable import SendLogWatchCore

/// Pins the WATCH's per-exercise side-applicability policy — a string-side
/// mirror of the iPhone's `ExerciseSideModeTests` (#720) and the web's
/// `src/lib/sideMode.test.ts` (#584). The default/legacy behavior and the
/// `""`/`"both"` distinction are the load-bearing contracts: an unconfigured
/// exercise must keep offering every side, and an empty side must never be
/// reinterpreted as `"both"`.
final class ForceSidePolicyTests: XCTestCase {
    private let allModes: [ForceSideMode] = [
        .unilateralOrBilateral,
        .unilateralOnly,
        .bilateralOnly,
        .notApplicable,
    ]

    private let allSides: [String] = [
        ForceSidePolicy.unspecified,
        ForceSidePolicy.left,
        ForceSidePolicy.right,
        ForceSidePolicy.both,
    ]

    // MARK: allowedSides / isSideAllowed

    func testAllowedSidesPolicyTableForAllModes() {
        XCTAssertEqual(
            ForceSidePolicy.allowedSides(.unilateralOrBilateral),
            ["", ForceSidePolicy.left, ForceSidePolicy.right, ForceSidePolicy.both]
        )
        XCTAssertEqual(
            ForceSidePolicy.allowedSides(.unilateralOnly),
            ["", ForceSidePolicy.left, ForceSidePolicy.right]
        )
        XCTAssertEqual(
            ForceSidePolicy.allowedSides(.bilateralOnly),
            ["", ForceSidePolicy.both]
        )
        XCTAssertEqual(
            ForceSidePolicy.allowedSides(.notApplicable),
            [""]
        )
    }

    func testAllowedSidesAlwaysIncludesUnspecified() {
        for mode in allModes {
            XCTAssertTrue(ForceSidePolicy.allowedSides(mode).contains(ForceSidePolicy.unspecified))
        }
    }

    func testIsSideAllowedMatchesAllowedSides() {
        for mode in allModes {
            for side in allSides {
                XCTAssertEqual(
                    ForceSidePolicy.isSideAllowed(mode, side),
                    ForceSidePolicy.allowedSides(mode).contains(side),
                    "mode \(mode) side \(side)"
                )
            }
        }
    }

    func testIsSideAllowedNeverTreatsUnspecifiedAsBoth() {
        XCTAssertTrue(ForceSidePolicy.isSideAllowed(.bilateralOnly, ForceSidePolicy.unspecified))
        XCTAssertTrue(ForceSidePolicy.isSideAllowed(.bilateralOnly, ForceSidePolicy.both))
        XCTAssertFalse(ForceSidePolicy.isSideAllowed(.notApplicable, ForceSidePolicy.both))
        XCTAssertTrue(ForceSidePolicy.isSideAllowed(.notApplicable, ForceSidePolicy.unspecified))
    }

    // MARK: showsSideSelector

    func testShowsSideSelectorByConcreteSidedness() {
        // Every sided exercise shows its relevant side choices (even a single
        // "Both" for bilateral-only), so "Both" is explicit, not implicit.
        XCTAssertTrue(ForceSidePolicy.showsSideSelector(.unilateralOrBilateral))
        XCTAssertTrue(ForceSidePolicy.showsSideSelector(.unilateralOnly))
        XCTAssertTrue(ForceSidePolicy.showsSideSelector(.bilateralOnly))
        // A non-sided exercise has no side decision to surface.
        XCTAssertFalse(ForceSidePolicy.showsSideSelector(.notApplicable))
    }

    func testIsSidedDistinguishesBilateralFromNotApplicable() {
        XCTAssertTrue(ForceSideMode.bilateralOnly.isSided)
        XCTAssertFalse(ForceSideMode.notApplicable.isSided)
        XCTAssertTrue(ForceSideMode.unilateralOrBilateral.isSided)
        XCTAssertTrue(ForceSideMode.unilateralOnly.isSided)
    }

    // MARK: normalizeSide

    func testNormalizeSideKeepsValidSideUnchanged() {
        XCTAssertEqual(ForceSidePolicy.normalizeSide(.unilateralOrBilateral, ForceSidePolicy.left), ForceSidePolicy.left)
        XCTAssertEqual(ForceSidePolicy.normalizeSide(.unilateralOrBilateral, ForceSidePolicy.both), ForceSidePolicy.both)
        XCTAssertEqual(ForceSidePolicy.normalizeSide(.unilateralOrBilateral, ForceSidePolicy.unspecified), ForceSidePolicy.unspecified)
        XCTAssertEqual(ForceSidePolicy.normalizeSide(.unilateralOnly, ForceSidePolicy.right), ForceSidePolicy.right)
        XCTAssertEqual(ForceSidePolicy.normalizeSide(.bilateralOnly, ForceSidePolicy.both), ForceSidePolicy.both)
        XCTAssertEqual(ForceSidePolicy.normalizeSide(.notApplicable, ForceSidePolicy.unspecified), ForceSidePolicy.unspecified)
    }

    func testNormalizeSideBilateralFallsBackToBoth() {
        XCTAssertEqual(ForceSidePolicy.normalizeSide(.bilateralOnly, ForceSidePolicy.left), ForceSidePolicy.both)
        XCTAssertEqual(ForceSidePolicy.normalizeSide(.bilateralOnly, ForceSidePolicy.right), ForceSidePolicy.both)
    }

    func testNormalizeSideNotApplicableFallsBackToUnspecified() {
        XCTAssertEqual(ForceSidePolicy.normalizeSide(.notApplicable, ForceSidePolicy.left), ForceSidePolicy.unspecified)
        XCTAssertEqual(ForceSidePolicy.normalizeSide(.notApplicable, ForceSidePolicy.right), ForceSidePolicy.unspecified)
        XCTAssertEqual(ForceSidePolicy.normalizeSide(.notApplicable, ForceSidePolicy.both), ForceSidePolicy.unspecified)
    }

    func testNormalizeSideUnilateralFallsBackToUnspecifiedForAmbiguousBoth() {
        XCTAssertEqual(ForceSidePolicy.normalizeSide(.unilateralOnly, ForceSidePolicy.both), ForceSidePolicy.unspecified)
    }

    func testNormalizeSideNeverReinterpretsHistoricalEmptyAsBoth() {
        for mode in allModes {
            XCTAssertEqual(ForceSidePolicy.normalizeSide(mode, ForceSidePolicy.unspecified), ForceSidePolicy.unspecified)
        }
    }

    // MARK: normalizeSideMode (ForceSideMode.normalize)

    func testNormalizeSideModePassesThroughEveryKnownMode() {
        for mode in allModes {
            XCTAssertEqual(ForceSideMode.normalize(mode.rawValue), mode)
        }
    }

    func testNormalizeSideModeDefaultsUnknownToUnilateralOrBilateral() {
        XCTAssertEqual(ForceSideMode.normalize("some_future_mode"), .unilateralOrBilateral)
        XCTAssertEqual(ForceSideMode.normalize(""), .unilateralOrBilateral)
    }

    func testNormalizeSideModeDefaultsMissingRegistryRowToUnilateralOrBilateral() {
        XCTAssertEqual(ForceSideMode.normalize(nil), .unilateralOrBilateral)
        XCTAssertEqual(ForceSideMode.defaultMode, .unilateralOrBilateral)
    }

    // MARK: recordedSide (save-time canonical side)

    func testRecordedSideBilateralIsAlwaysBoth() {
        XCTAssertEqual(ForceSidePolicy.recordedSide(.bilateralOnly, ForceSidePolicy.unspecified), ForceSidePolicy.both)
        XCTAssertEqual(ForceSidePolicy.recordedSide(.bilateralOnly, ForceSidePolicy.both), ForceSidePolicy.both)
        XCTAssertEqual(ForceSidePolicy.recordedSide(.bilateralOnly, ForceSidePolicy.left), ForceSidePolicy.both)
        XCTAssertEqual(ForceSidePolicy.recordedSide(.bilateralOnly, ForceSidePolicy.right), ForceSidePolicy.both)
    }

    func testRecordedSideNotApplicableIsAlwaysUnspecified() {
        XCTAssertEqual(ForceSidePolicy.recordedSide(.notApplicable, ForceSidePolicy.unspecified), ForceSidePolicy.unspecified)
        XCTAssertEqual(ForceSidePolicy.recordedSide(.notApplicable, ForceSidePolicy.left), ForceSidePolicy.unspecified)
        XCTAssertEqual(ForceSidePolicy.recordedSide(.notApplicable, ForceSidePolicy.both), ForceSidePolicy.unspecified)
    }

    func testRecordedSideKeepsValidUnilateralSide() {
        XCTAssertEqual(ForceSidePolicy.recordedSide(.unilateralOnly, ForceSidePolicy.left), ForceSidePolicy.left)
        XCTAssertEqual(ForceSidePolicy.recordedSide(.unilateralOnly, ForceSidePolicy.right), ForceSidePolicy.right)
        XCTAssertEqual(ForceSidePolicy.recordedSide(.unilateralOnly, ForceSidePolicy.unspecified), ForceSidePolicy.unspecified)
        XCTAssertEqual(ForceSidePolicy.recordedSide(.unilateralOrBilateral, ForceSidePolicy.left), ForceSidePolicy.left)
        XCTAssertEqual(ForceSidePolicy.recordedSide(.unilateralOrBilateral, ForceSidePolicy.both), ForceSidePolicy.both)
    }

    func testRecordedSideChangesWithModeWhileSideStaysUnspecified() {
        let side = ForceSidePolicy.unspecified
        XCTAssertEqual(ForceSidePolicy.recordedSide(.bilateralOnly, side), ForceSidePolicy.both)
        XCTAssertEqual(ForceSidePolicy.recordedSide(.notApplicable, side), ForceSidePolicy.unspecified)
    }

    // MARK: ForceSideMemory (per-exercise remembered side)

    private let suiteName = "ForceSidePolicyTests.\(UUID().uuidString)"
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

    func testRememberedSideStoreAndReadRoundTrip() {
        ForceSideMemory.store(side: ForceSidePolicy.left, for: "half crimp", defaults: defaults)
        XCTAssertEqual(ForceSideMemory.storedSide(for: "half crimp", defaults: defaults), ForceSidePolicy.left)
        ForceSideMemory.store(side: ForceSidePolicy.both, for: "sloper", defaults: defaults)
        XCTAssertEqual(ForceSideMemory.storedSide(for: "sloper", defaults: defaults), ForceSidePolicy.both)
    }

    func testRememberedSideDoesNotLeakAcrossExercises() {
        ForceSideMemory.store(side: ForceSidePolicy.left, for: "half crimp", defaults: defaults)
        XCTAssertNil(ForceSideMemory.storedSide(for: "sloper", defaults: defaults))
        XCTAssertNil(ForceSideMemory.storedSide(for: "pinch block", defaults: defaults))
        XCTAssertEqual(ForceSideMemory.storedSide(for: "half crimp", defaults: defaults), ForceSidePolicy.left)
    }

    func testRestoreValidSideRestoresRememberedValidSide() {
        ForceSideMemory.store(side: ForceSidePolicy.right, for: "half crimp", defaults: defaults)
        XCTAssertEqual(
            ForceSideMemory.restoreValidSide(mode: .unilateralOrBilateral, name: "half crimp", defaults: defaults),
            ForceSidePolicy.right
        )
        XCTAssertEqual(
            ForceSideMemory.restoreValidSide(mode: .unilateralOnly, name: "half crimp", defaults: defaults),
            ForceSidePolicy.right
        )
    }

    func testRestoreValidSideFallsBackForNoRememberedSide() {
        // No remembered side for a bilateral-only exercise → deterministic "both".
        XCTAssertEqual(
            ForceSideMemory.restoreValidSide(mode: .bilateralOnly, name: "half crimp", defaults: defaults),
            ForceSidePolicy.both
        )
        // No remembered side for a not-applicable exercise → no side.
        XCTAssertEqual(
            ForceSideMemory.restoreValidSide(mode: .notApplicable, name: "half crimp", defaults: defaults),
            ForceSidePolicy.unspecified
        )
        // No remembered side for a unilateral exercise → no chosen side yet.
        XCTAssertEqual(
            ForceSideMemory.restoreValidSide(mode: .unilateralOrBilateral, name: "half crimp", defaults: defaults),
            ForceSidePolicy.unspecified
        )
    }

    func testRestoreValidSideDropsSideInvalidUnderIncompatibleMode() {
        // A change of side mode must not resurrect a now-incompatible side.
        ForceSideMemory.store(side: ForceSidePolicy.both, for: "half crimp", defaults: defaults)
        XCTAssertEqual(
            ForceSideMemory.restoreValidSide(mode: .unilateralOnly, name: "half crimp", defaults: defaults),
            ForceSidePolicy.unspecified
        )
        ForceSideMemory.store(side: ForceSidePolicy.left, for: "sloper", defaults: defaults)
        XCTAssertEqual(
            ForceSideMemory.restoreValidSide(mode: .notApplicable, name: "sloper", defaults: defaults),
            ForceSidePolicy.unspecified
        )
        // A bilateral-only exercise is inherently both-sided: left is corrected to both.
        ForceSideMemory.store(side: ForceSidePolicy.left, for: "pinch", defaults: defaults)
        XCTAssertEqual(
            ForceSideMemory.restoreValidSide(mode: .bilateralOnly, name: "pinch", defaults: defaults),
            ForceSidePolicy.both
        )
    }

    func testRestoreValidSideNeverReinterpretsEmptyAsBoth() {
        // An explicitly remembered empty side reads as "no remembered side",
        // so for a unilateral/both-possible exercise the restore stays "" —
        // a historical empty value is never rewritten to "both".
        defaults.set("", forKey: ForceSideMemory.storageKey(for: "half crimp"))
        XCTAssertEqual(
            ForceSideMemory.restoreValidSide(mode: .unilateralOrBilateral, name: "half crimp", defaults: defaults),
            ForceSidePolicy.unspecified
        )
        // For a bilateral-only exercise the canonical freshly-stamped side is
        // "both" regardless of a legacy empty memory — the mode's default, not
        // a reinterpretation of the stored "".
        XCTAssertEqual(
            ForceSideMemory.restoreValidSide(mode: .bilateralOnly, name: "half crimp", defaults: defaults),
            ForceSidePolicy.both
        )
    }

    func testRemoveClearsRememberedSide() {
        ForceSideMemory.store(side: ForceSidePolicy.left, for: "half crimp", defaults: defaults)
        ForceSideMemory.remove(for: "half crimp", defaults: defaults)
        XCTAssertNil(ForceSideMemory.storedSide(for: "half crimp", defaults: defaults))
    }
}
