import XCTest
@testable import SendmeterCore

final class MassFormattingTests: XCTestCase {
    private let suiteName = "MassFormattingTests.\(UUID().uuidString)"
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

    // MARK: - kg → lb rounding

    func testKilogramsToPoundsRoundsToOneDecimal() {
        // 62.8 kg * 2.20462… = 138.450… → 138.5 lb (the example from #721).
        XCTAssertEqual(
            MassFormatting.format(62.8, in: .pounds),
            "138.5 lb",
            "62.8 kg should round sensibly to 138.5 lb"
        )
    }

    func testKilogramValueIsUnrounded() {
        // The value conversion is raw; only the formatter rounds.
        XCTAssertEqual(MassFormatting.value(1, in: .pounds), 2.204_622_621_848_775, accuracy: 1e-12)
    }

    // MARK: - Formatter output in both systems

    func testMetricFormatterOutputIsByteIdentical() {
        XCTAssertEqual(MassFormatting.format(62.8, in: .kilograms), "62.8 kg")
        XCTAssertEqual(MassFormatting.format(0, in: .kilograms), "0.0 kg")
        XCTAssertEqual(MassFormatting.format(73.4, in: .kilograms), "73.4 kg")
    }

    func testImperialFormatterOutput() {
        XCTAssertEqual(MassFormatting.format(62.8, in: .pounds), "138.5 lb")
        XCTAssertEqual(MassFormatting.format(0, in: .pounds), "0.0 lb")
    }

    func testFormatterUsesStoredPreference() {
        AppUnits.store(.metric, defaults: defaults)
        XCTAssertEqual(MassFormatting.storedFormatted(62.8, defaults: defaults), "62.8 kg")

        AppUnits.store(.imperial, defaults: defaults)
        XCTAssertEqual(MassFormatting.storedFormatted(62.8, defaults: defaults), "138.5 lb")
    }

    // MARK: - Round-trip tolerance

    func testKilogramsToPoundsToKilogramsRoundTripsWithinTolerance() {
        let samples: [Double] = [62.8, 0, 1, 45.2, 100, 88.3]
        for kilograms in samples {
            let pounds = MassFormatting.value(kilograms, in: .pounds)
            let back = MassFormatting.kilograms(from: pounds, in: .pounds)
            XCTAssertEqual(
                back, kilograms, accuracy: 1e-6,
                "kg→lb→kg must round-trip for \(kilograms) kg"
            )
        }
    }

    // MARK: - Preference normalization

    func testUnitForPreference() {
        XCTAssertEqual(MassFormatting.unit(for: .metric), .kilograms)
        XCTAssertEqual(MassFormatting.unit(for: .imperial), .pounds)
    }

    func testFormatForPreference() {
        XCTAssertEqual(MassFormatting.format(62.8, for: .metric), "62.8 kg")
        XCTAssertEqual(MassFormatting.format(62.8, for: .imperial), "138.5 lb")
    }

    // MARK: - Storage-failure fallback to metric

    func testEmptyStorageFallsBackToMetric() {
        // Nothing stored in this suite — reading the preference fails and the
        // shared helper must fall back to the metric default.
        XCTAssertEqual(AppUnits.storedChoice(defaults: defaults), .metric)
        XCTAssertEqual(MassFormatting.storedFormatted(62.8, defaults: defaults), "62.8 kg")
    }

    func testGarbageStorageFallsBackToMetric() {
        defaults.set("stones", forKey: AppUnits.storageKey)
        XCTAssertEqual(AppUnits.storedChoice(defaults: defaults), .metric)
        XCTAssertEqual(MassFormatting.storedFormatted(62.8, defaults: defaults), "62.8 kg")
    }

    // MARK: - Symbols

    func testUnitSymbols() {
        XCTAssertEqual(MassUnit.kilograms.symbol, "kg")
        XCTAssertEqual(MassUnit.pounds.symbol, "lb")
    }
}
