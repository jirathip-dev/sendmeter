import Foundation
import SendLogWatchCore
import XCTest

/// #1028 B2: one shared palette, enforced. A colour literal — a hex string,
/// `Color(hex:)`, an RGB/`PhaseRGB` numeric constructor — may only live in a
/// token file. Any new literal anywhere else in the phone app, the Watch app
/// or the Watch widgets fails this test with its file and line.
///
/// `Color.white` / `Color.black` overlays are ratcheted rather than banned:
/// the Watch still paints a few white-opacity highlights (glass edges,
/// pressed states). The count may only go down; the rollout removes the rest.
final class SendmeterPaletteGateTests: XCTestCase {
    /// Token files: the only places a colour literal may appear.
    private static let tokenFiles: Set<String> = [
        "ios/App/SendLogWatchCore/Sources/SendLogWatchCore/SendmeterPalette.swift",
        "ios/App/SendLogWatchCore/Sources/SendLogWatchCore/WatchDesign.swift",
        "ios/App/SendLogWatchCore/Sources/SendLogWatchCore/WorkoutPhaseFill.swift",
        "native/SendmeterNative/Sources/App/DesignSystem.swift",
        "native/SendmeterNative/Sources/App/ChartTheme.swift",
        // Contrast policies whose hex constants are pinned by their own tests.
        "native/SendmeterNative/Sources/Core/ChartContrast.swift",
        "native/SendmeterNative/Sources/Core/RoutineRunnerContrast.swift",
        // Phase catalog `colorHex` is persisted data mirrored from the web.
        "native/SendmeterNative/Sources/Core/Models.swift",
    ]

    /// Files that convert an already-resolved token to a SwiftUI `Color`
    /// (`Color(red: token.red, …)`) — a conversion seam, not a new literal.
    private static let conversionSeams: Set<String> = [
        "ios/App/SendLogWatch Watch App/Shared/WatchDesignSystem.swift",
        "ios/App/SendLogWatch Watch App/Views/WorkoutLiveView.swift",
        "ios/App/SendLogWatchWidgets/StatusColors.swift",
        "ios/App/SendLogWatchWidgets/LiveWorkoutWidget.swift",
        "native/SendmeterNative/Sources/Features/Dashboard/RecoveryInputsSheet.swift",
    ]

    private static let scannedRoots = [
        "native/SendmeterNative/Sources",
        "ios/App/SendLogWatch Watch App",
        "ios/App/SendLogWatchWidgets",
        "ios/App/SendLogWatchCore/Sources",
    ]

    /// Literal patterns. A conversion seam may use `Color(red: x.red …)` but
    /// never a numeric literal, so seams are checked with the numeric forms.
    private static let literalPatterns = [
        ##""#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?""##,
        #"Color\(hex:"#,
        #"Color\(red:\s*[0-9.]"#,
        #"Color\(\.sRGB"#,
        #"UIColor\(red:\s*[0-9.]"#,
        #"UIColor\(white:\s*[0-9.]"#,
        #"Color\(white:\s*[0-9.]"#,
        #"PhaseRGB\(\s*[0-9.]"#,
        #"PhaseRGB\(\s*0x"#,
    ]

    /// The `Color.white` / `Color.black` count at #1028 (measured at the
    /// #1030 head). It may only shrink.
    private static let whiteBlackOverlayCeiling = 20

    func testNoColorLiteralOutsideTokenFiles() throws {
        let root = Self.repositoryRoot()
        var offenders: [String] = []
        for file in try Self.swiftFiles(under: root) {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            guard !Self.tokenFiles.contains(relative) else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let code = Self.stripComment(line)
                for pattern in Self.literalPatterns where code.range(of: pattern, options: .regularExpression) != nil {
                    offenders.append("\(relative):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "colour literals must live in the shared token files (#1028 B2):\n" + offenders.joined(separator: "\n")
        )
    }

    func testConversionSeamsStillExist() {
        let root = Self.repositoryRoot()
        for seam in Self.conversionSeams {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(seam).path),
                "\(seam) is listed as a conversion seam but no longer exists — drop it from the list"
            )
        }
    }

    func testWhiteBlackOverlaysOnlyShrink() throws {
        let root = Self.repositoryRoot()
        var count = 0
        for file in try Self.swiftFiles(under: root) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.components(separatedBy: "\n") {
                let code = Self.stripComment(line)
                count += code.components(separatedBy: "Color.white").count - 1
                count += code.components(separatedBy: "Color.black").count - 1
            }
        }
        XCTAssertLessThanOrEqual(
            count,
            Self.whiteBlackOverlayCeiling,
            "new Color.white/Color.black literal — use a SendmeterPalette token (#1028 B2)"
        )
    }

    func testGateCatchesAPlantedLiteral() {
        // RED probe for the scanner itself: each pattern must match its
        // canonical offender, so a broken regex cannot pass silently.
        let planted = [
            ##"let x = Color(hex: "#123456")"##,
            ##"let y = "#ABCDEF""##,
            "let z = Color(red: 0.2, green: 0.3, blue: 0.4)",
            "let w = PhaseRGB(0.30, 0.93, 0.68)",
            "let v = PhaseRGB(0x4F / 255, 0xB0 / 255, 0xFF / 255)",
        ]
        for line in planted {
            XCTAssertTrue(
                Self.literalPatterns.contains { line.range(of: $0, options: .regularExpression) != nil },
                "the gate must catch: \(line)"
            )
        }
        XCTAssertNil(
            "Color(red: rgb.red, green: rgb.green, blue: rgb.blue)"
                .range(of: #"Color\(red:\s*[0-9.]"#, options: .regularExpression),
            "a token conversion seam is not a literal"
        )
    }

    /// #1028 P6: the Watch rest-target chips paint the phone's resting hue.
    /// This replaces the deleted Watch screenshot suite's cyan selector-pixel
    /// pin (`restTargetRamp`'s 120 s cyan, PhaseRGB(0.18, 0.84, 0.96)) on
    /// purpose: the per-duration ramp is retired, not kept.
    func testWatchRestTargetsPaintThePhoneRestingHue() throws {
        let path = "ios/App/SendLogWatch Watch App/Views/WorkoutLiveView.swift"
        let source = try String(contentsOf: Self.repositoryRoot().appendingPathComponent(path), encoding: .utf8)
        XCTAssertTrue(source.contains("private static let restTargetTint = SendmeterPalette.rest.rgb(isDark: true)"))
        XCTAssertTrue(source.contains("let tint = Self.restTargetTint"))
        XCTAssertFalse(source.contains("restTargetRamp"), "the per-duration rest ramp is retired (#1028 P6)")
        XCTAssertEqual(SendmeterPalette.rest, SendmeterPalette.primary)
    }

    // MARK: Helpers

    static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SendmeterCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // SendmeterNative
            .deletingLastPathComponent() // native
            .deletingLastPathComponent() // repo root
    }

    private static func swiftFiles(under root: URL) throws -> [URL] {
        var files: [URL] = []
        for scanned in scannedRoots {
            let directory = root.appendingPathComponent(scanned)
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                files.append(url.resolvingSymlinksInPath())
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func stripComment(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*") { return "" }
        if let range = line.range(of: " // ") { return String(line[..<range.lowerBound]) }
        return line
    }
}

/// #1028 B3: every text pair the refined surfaces paint meets WCAG AA in
/// both themes. A pair below AA must be listed as an owner exception in
/// `docs/design/tokens.md` AND here — never relaxed silently.
final class SendmeterPaletteContrastTests: XCTestCase {
    /// Owner-approved exceptions (none at #1028).
    private let exceptions: Set<String> = []

    /// The approved #1028 matrix is 81 text pairs; a pair dropped from the
    /// registry would otherwise pass silently.
    func testTheRegistryIsTheApproved81Pairs() {
        XCTAssertEqual(SendmeterPalette.textPairs.count, 81)
        XCTAssertEqual(Set(SendmeterPalette.textPairs.map(\.name)).count, 81)
    }

    /// B3: the pill label is the hue mixed into `textPrimary` at 45 %, and
    /// that mix — not the raw hue — clears AA on every pill surface. The raw
    /// caution hue on its own tint is the build-57 failure this replaces.
    func testPillLabelIsTheHueMixedIntoTextAt45Percent() {
        XCTAssertEqual(SendmeterPalette.pillTextHueWeight, 0.45)
        let caution = SendmeterPalette.caution
        XCTAssertEqual(
            SendmeterPalette.pillText(caution).light,
            SendmeterPalette.composite(caution.light, over: SendmeterPalette.textPrimary.light, alpha: 0.45)
        )
        let rawLight = caution.rgb(isDark: false).contrastRatio(
            to: SendmeterPalette.pillFill(caution, on: SendmeterPalette.surface).rgb(isDark: false)
        )
        XCTAssertLessThan(rawLight, 4.5, "the raw hue was the failure; the mix must be what clears AA")
        let pills = SendmeterPalette.textPairs.filter { $0.name.hasPrefix("pill ") }
        XCTAssertEqual(pills.count, 48)
        for pair in pills {
            XCTAssertGreaterThanOrEqual(min(pair.ratio(isDark: false), pair.ratio(isDark: true)), 4.5, pair.name)
        }
    }

    func testEveryTextPairMeetsAAInBothThemes() {
        for pair in SendmeterPalette.textPairs where !exceptions.contains(pair.name) {
            for isDark in [false, true] {
                XCTAssertGreaterThanOrEqual(
                    pair.ratio(isDark: isDark),
                    pair.minimum,
                    "\(pair.name) (\(isDark ? "dark" : "light")) is below AA"
                )
            }
        }
    }

    func testWatchSurfacesAreThePhoneDarkRamp() {
        XCTAssertEqual(WatchDesignTokens.canvas, SendmeterPalette.canvas.rgb(isDark: true))
        XCTAssertEqual(WatchDesignTokens.canvasRaised, SendmeterPalette.surface.rgb(isDark: true))
        XCTAssertEqual(WatchDesignTokens.card, SendmeterPalette.surfaceRaised.rgb(isDark: true))
        XCTAssertEqual(WatchDesignTokens.cardStrong, SendmeterPalette.surfaceNested.rgb(isDark: true))
        XCTAssertEqual(WatchDesignTokens.textPrimary, SendmeterPalette.textPrimary.rgb(isDark: true))
        XCTAssertEqual(WatchDesignTokens.success, SendmeterPalette.success.rgb(isDark: true))
    }

    func testSemanticFillsAreTheCanonicalHues() {
        XCTAssertEqual(SendmeterPalette.primary.light, SendmeterSemanticHue.primary.hex)
        XCTAssertEqual(SendmeterPalette.optimal.light, SendmeterSemanticHue.optimal.hex)
        XCTAssertEqual(SendmeterPalette.caution.light, SendmeterSemanticHue.caution.hex)
        XCTAssertEqual(SendmeterPalette.danger.light, SendmeterSemanticHue.danger.hex)
        XCTAssertEqual(SendmeterPalette.execution.light, SendmeterSemanticHue.execution.hex)
    }
}
