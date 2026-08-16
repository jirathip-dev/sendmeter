import SwiftUI
import XCTest
@testable import SendmeterCore

/// Pins ChartTheme.swift's hex table to `src/index.css` so CSS drift is
/// caught by a diff instead of silently shipping a divergent palette (#649).
final class ChartThemeTests: XCTestCase {
    /// The 13 semantic tokens, light → dark, exactly as in index.css
    /// (`:root` ~L157-177 / `.dark` ~L356-377).
    private let expectedTokenHexes: [ChartToken: (light: String, dark: String)] = [
        .focus: ("#5B5FC7", "#9296EE"),
        .health: ("#2E96F0", "#4FB0FF"),
        .load: ("#7B83EB", "#9296EE"),
        .force: ("#5B5FC7", "#9296EE"),
        .forceSecondary: ("#2E96F0", "#4FB0FF"),
        .optimal: ("#2E96F0", "#4FB0FF"),
        .caution: ("#DDB13A", "#E8C24E"),
        .alert: ("#E5743A", "#F0864C"),
        .reference: ("#8E8E93", "#A9A9B0"),
        .grid: ("#E2E2E6", "#3E3E44"),
        .axis: ("#6E6E73", "#A9A9B0"),
        .tooltip: ("#FFFFFF", "#2C2C31"),
        .tooltipBorder: ("#D8D8DC", "#4A4A50")
    ]

    /// The 11 activity hues, light → dark (`--chart-activity-*`). `auto` and
    /// `custom` are single-hue in the CSS (same value in both modes).
    private let expectedActivityHexes: [ChartActivityHue: (light: String, dark: String)] = [
        .board: ("#2E96F0", "#4FB0FF"),
        .fingerboard: ("#7B83EB", "#9296EE"),
        .gym: ("#5B5FC7", "#9296EE"),
        .outdoor: ("#218E98", "#65D2DB"),
        .arc: ("#1682A5", "#66D5EF"),
        .antagonist: ("#7752A8", "#B18AE8"),
        .routine: ("#A94D7D", "#E39AC3"),
        .campus: ("#C96032", "#F0864C"),
        .tindeq: ("#B96C2C", "#E8A24D"),
        .auto: ("#2A82C5", "#77C8F5"),
        .custom: ("#6E6E73", "#A9A9B0")
    ]

    // MARK: Semantic tokens

    func testSemanticTokenCountIsThirteen() {
        XCTAssertEqual(ChartToken.allCases.count, 13)
        XCTAssertEqual(Set(ChartToken.allCases.map(\.rawValue)).count, 13, "rawValues must be unique")
    }

    func testSemanticTokenHexesMatchCSS() {
        for (token, expected) in expectedTokenHexes {
            XCTAssertEqual(token.lightHex, expected.light, "\(token.rawValue) light hex")
            XCTAssertEqual(token.darkHex, expected.dark, "\(token.rawValue) dark hex")
        }
    }

    func testSemanticTokenHexesAreExhaustivelyPinned() {
        XCTAssertEqual(ChartToken.allCases.count, expectedTokenHexes.count, "every token must be pinned")
        for token in ChartToken.allCases {
            XCTAssertNotNil(expectedTokenHexes[token], "token \(token.rawValue) is missing from the expected table")
        }
    }

    func testHexForSchemeResolvesPerAppearance() {
        for token in ChartToken.allCases {
            XCTAssertEqual(token.hex(for: .light), token.lightHex)
            XCTAssertEqual(token.hex(for: .dark), token.darkHex)
        }
    }

    // MARK: Activity hues

    func testActivityHueCountIsEleven() {
        XCTAssertEqual(ChartActivityHue.allCases.count, 11)
        XCTAssertEqual(Set(ChartActivityHue.allCases.map(\.rawValue)).count, 11, "rawValues must be unique")
    }

    func testActivityHueHexesMatchCSS() {
        for (hue, expected) in expectedActivityHexes {
            XCTAssertEqual(hue.lightHex, expected.light, "\(hue.rawValue) light hex")
            XCTAssertEqual(hue.darkHex, expected.dark, "\(hue.rawValue) dark hex")
        }
    }

    func testActivityHuesAreExhaustivelyPinned() {
        XCTAssertEqual(ChartActivityHue.allCases.count, expectedActivityHexes.count, "every hue must be pinned")
        for hue in ChartActivityHue.allCases {
            XCTAssertNotNil(expectedActivityHexes[hue], "hue \(hue.rawValue) is missing from the expected table")
        }
    }

    func testEveryActivityHueDiffersBetweenSchemes() {
        for hue in ChartActivityHue.allCases {
            XCTAssertNotEqual(hue.lightHex, hue.darkHex, "\(hue.rawValue) is expected to brighten in dark mode")
        }
    }

    // MARK: Activity-id resolution

    func testUnknownActivityFallsBackToReference() {
        let light = ChartActivityHue.color(forActivityID: "not-a-real-activity", scheme: .light)
        let dark = ChartActivityHue.color(forActivityID: "not-a-real-activity", scheme: .dark)
        XCTAssertEqual(light, ChartToken.reference.color(.light))
        XCTAssertEqual(dark, ChartToken.reference.color(.dark))
    }

    func testEmptyActivityIDFallsBackToReference() {
        XCTAssertEqual(
            ChartActivityHue.color(forActivityID: "", scheme: .light),
            ChartToken.reference.color(.light)
        )
    }

    func testKnownActivityIDResolvesToItsHue() {
        XCTAssertEqual(
            ChartActivityHue.color(forActivityID: ChartActivityHue.tindeq.rawValue, scheme: .dark),
            ChartActivityHue.tindeq.color(.dark)
        )
        XCTAssertEqual(
            ChartActivityHue.color(forActivityID: ChartActivityHue.board.rawValue, scheme: .light),
            ChartActivityHue.board.color(.light)
        )
    }

    // MARK: Gradients

    func testAreaOpacityMatchesCSS() {
        for token in ChartToken.allCases {
            XCTAssertEqual(token.areaOpacity(.light), 0.16, "\(token.rawValue) light area opacity")
            XCTAssertEqual(token.areaOpacity(.dark), 0.20, "\(token.rawValue) dark area opacity")
        }
    }

    func testBandOpacityMatchesCSS() {
        for token in ChartToken.allCases {
            XCTAssertEqual(token.bandOpacity(.light), 0.12, "\(token.rawValue) light band opacity")
            XCTAssertEqual(token.bandOpacity(.dark), 0.16, "\(token.rawValue) dark band opacity")
        }
    }

    func testAreaGradientBottomStopPerChartDefs() {
        for token in ChartToken.allCases {
            if token == .load || token == .force {
                XCTAssertEqual(token.areaBottomOpacity, 0.04, "\(token.rawValue) bottom stop")
            } else {
                XCTAssertEqual(token.areaBottomOpacity, 0.03, "\(token.rawValue) bottom stop")
            }
        }
    }

    func testSelectedHaloStopsMatchChartDefs() {
        let stops = ChartToken.selectedHaloStops
        XCTAssertEqual(stops.count, 3)
        XCTAssertEqual(stops.map(\.opacity), [0.28, 0.08, 0])
        XCTAssertEqual(stops.map(\.location), [0, 0.7, 1])
    }

    func testColorsResolveForBothSchemes() {
        for token in ChartToken.allCases {
            XCTAssertNotNil(token.color(.light), "\(token.rawValue) light color")
            XCTAssertNotNil(token.color(.dark), "\(token.rawValue) dark color")
        }
        for hue in ChartActivityHue.allCases {
            XCTAssertNotNil(hue.color(.light), "\(hue.rawValue) light color")
            XCTAssertNotNil(hue.color(.dark), "\(hue.rawValue) dark color")
        }
        XCTAssertNotNil(ChartToken.selectedHalo(.dark), "selected halo")
    }
}
