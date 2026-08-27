import XCTest
@testable import SendmeterCore

final class StructuralHapticDiagnosticsTests: XCTestCase {
    func testMissingOrReleaseArgumentsUseTheNormalDefault() {
        XCTAssertEqual(
            StructuralHapticDiagnosticMode.resolve(
                arguments: [],
                debugBuild: true
            ),
            .normal
        )
        XCTAssertEqual(
            StructuralHapticDiagnosticMode.resolve(
                arguments: [
                    StructuralHapticDiagnosticMode.launchArgument,
                    "b"
                ],
                debugBuild: false
            ),
            .normal
        )
    }

    func testDebugArgumentsSelectVisibleAAndBVariants() {
        let argument = StructuralHapticDiagnosticMode.launchArgument

        XCTAssertEqual(
            StructuralHapticDiagnosticMode.resolve(
                arguments: [argument, "A"],
                debugBuild: true
            ),
            .control
        )
        XCTAssertEqual(
            StructuralHapticDiagnosticMode.resolve(
                arguments: [argument, "B"],
                debugBuild: true
            ),
            .rootGestureDisabled
        )
        XCTAssertEqual(
            StructuralHapticDiagnosticMode.resolve(
                arguments: [argument, "b-prime"],
                debugBuild: true
            ),
            .explicitTapDisabled
        )
        XCTAssertEqual(
            StructuralHapticDiagnosticMode.resolve(
                arguments: [argument, "b-plus-prime"],
                debugBuild: true
            ),
            .allStructuralGesturesDisabled
        )
        XCTAssertEqual(
            StructuralHapticDiagnosticMode.resolve(
                arguments: [argument, "unknown"],
                debugBuild: true
            ),
            .normal
        )
    }

    func testBAndBPrimeDisableOnlyTheirNamedGestureSource() {
        XCTAssertEqual(
            StructuralHapticDiagnosticMode.normal.tapPolicy,
            StructuralHapticTapPolicy(
                rootDefaultEnabled: true,
                explicitEnabled: true,
                attachment: .scrollSafe
            )
        )
        XCTAssertEqual(
            StructuralHapticDiagnosticMode.control.tapPolicy,
            StructuralHapticTapPolicy(
                rootDefaultEnabled: true,
                explicitEnabled: true,
                attachment: .legacyZeroDistance
            )
        )
        XCTAssertEqual(
            StructuralHapticDiagnosticMode.rootGestureDisabled.tapPolicy,
            StructuralHapticTapPolicy(
                rootDefaultEnabled: false,
                explicitEnabled: true,
                attachment: .legacyZeroDistance
            )
        )
        XCTAssertEqual(
            StructuralHapticDiagnosticMode.explicitTapDisabled.tapPolicy,
            StructuralHapticTapPolicy(
                rootDefaultEnabled: true,
                explicitEnabled: false,
                attachment: .legacyZeroDistance
            )
        )
        XCTAssertEqual(
            StructuralHapticDiagnosticMode.allStructuralGesturesDisabled.tapPolicy,
            StructuralHapticTapPolicy(
                rootDefaultEnabled: false,
                explicitEnabled: false,
                attachment: .legacyZeroDistance
            )
        )
    }

    func testDiagnosticLabelsMakeTheSelectedVariantObservable() {
        XCTAssertNil(StructuralHapticDiagnosticMode.normal.displayLabel)
        XCTAssertTrue(
            StructuralHapticDiagnosticMode.control.displayLabel?.contains("A") == true
        )
        XCTAssertTrue(
            StructuralHapticDiagnosticMode.rootGestureDisabled.displayLabel?.contains("B") == true
        )
        XCTAssertTrue(
            StructuralHapticDiagnosticMode.explicitTapDisabled.displayLabel?.contains("B′") == true
        )
        XCTAssertTrue(
            StructuralHapticDiagnosticMode.allStructuralGesturesDisabled.displayLabel?.contains("B+B′") == true
        )
    }
}
