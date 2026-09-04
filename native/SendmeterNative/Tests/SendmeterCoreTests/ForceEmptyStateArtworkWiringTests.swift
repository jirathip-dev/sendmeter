import CryptoKit
import Foundation
import XCTest

/// #894: the Force disconnected/empty-state Progressor card must present the
/// approved R11 Force master as a large standalone template glyph (the 160 px
/// hero optical variant), never the splash cave/photo composite. The swap is
/// wired through the shared ProductEmptyState seam: every OTHER surface keeps
/// the splash default and the Force device empty state opts in via
/// `artwork: .forceMascot`. Source-text pins (the SwiftUI app target is
/// outside SwiftPM) following EmptyStateWiringTests /
/// TabGlyphRenderingWiringTests conventions.
final class ForceEmptyStateArtworkWiringTests: XCTestCase {
    /// Approved #868/#875 R11 Force 160 px hero master SHA-256 (byte-identical
    /// to the design worktree's revision-16 output and the committed
    /// ForceMascotLarge.imageset asset).
    private let approvedR11HeroMasterSHA256 =
        "6802e9439ff2fbcd70f60e7f04baf2196c33cf17de6ad309716966221ede6380"

    func testForceDeviceEmptyStateOptsIntoApprovedMascotArtwork() throws {
        let forceView = code(source("Sources/Features/Force/ForceView.swift"))
        let deviceCard = exactBlock(
            forceView,
            startingWith: "private struct ForceDeviceCard: View"
        )

        XCTAssertTrue(
            deviceCard.contains("ProductEmptyState("),
            "the disconnected/empty Progressor card must keep the shared empty-state layout"
        )
        XCTAssertTrue(
            deviceCard.contains("artwork: .forceMascot"),
            "the Force empty state must opt into the approved mascot artwork; the cave/photo composite is banned on this surface"
        )
        XCTAssertTrue(
            deviceCard.contains("\"Reconnect to your force progress\""),
            "the reconnect copy must stay on the Force empty state"
        )
        XCTAssertTrue(deviceCard.contains("actionTitle: emptyActionTitle"))
        XCTAssertTrue(deviceCard.contains("action: emptyAction"))
        XCTAssertEqual(
            countOccurrences("artwork: .forceMascot", in: forceView),
            1,
            "only the Force device empty state opts into the mascot artwork today"
        )
    }

    func testProductEmptyStateShipsMascotArtworkAndKeepsSplashDefault() throws {
        let design = code(source("Sources/App/DesignSystem.swift"))
        XCTAssertTrue(design.contains("enum ProductEmptyStateArtwork"))
        XCTAssertTrue(design.contains("case forceMascot"))

        let emptyState = exactBlock(
            design,
            startingWith: "public struct ProductEmptyState: View"
        )
        // The mascot branch wires the approved hero imageset as a template
        // silhouette (native tint axis). Absent on the old cave composite.
        XCTAssertTrue(emptyState.contains("case .forceMascot:"))
        XCTAssertTrue(emptyState.contains("Image(\"ForceMascotLarge\")"))
        XCTAssertTrue(emptyState.contains(".renderingMode(.template)"))
        XCTAssertTrue(
            emptyState.contains(".foregroundStyle(SendmeterStyle.primary)"),
            "the hero glyph must take the native primary tint"
        )
        // Every other empty-state surface keeps the splash composite default.
        XCTAssertTrue(emptyState.contains("case .splash:"))
        XCTAssertTrue(emptyState.contains("Image(\"SplashCaveBackground\")"))
        XCTAssertTrue(emptyState.contains("Image(\"SplashKangaroo\")"))
        // One-action / haptics / accessibility contract is unchanged.
        XCTAssertEqual(
            countOccurrences("Button(actionTitle, action: action)", in: emptyState),
            1,
            "an empty state must expose exactly one primary next action"
        )
        XCTAssertTrue(emptyState.contains(".hapticButtonStyle(PrimaryActionButtonStyle())"))
        XCTAssertTrue(emptyState.contains(".accessibilityHidden(true)"))
    }

    func testForceMascotLargeAssetIsApprovedHeroMaster() throws {
        let contentsURL = packageRoot().appendingPathComponent(
            "Resources/Assets.xcassets/ForceMascotLarge.imageset/Contents.json"
        )
        let contents = try JSONSerialization.jsonObject(with: Data(contentsOf: contentsURL))
            as? [String: Any]
        let images = try XCTUnwrap(contents?["images"] as? [[String: Any]])
        let filename = try XCTUnwrap(images.first?["filename"] as? String)
        XCTAssertEqual(filename, "r11-force-control-160.svg")

        let masterURL = packageRoot().appendingPathComponent(
            "Resources/Assets.xcassets/ForceMascotLarge.imageset/r11-force-control-160.svg"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: masterURL.path),
            "the approved R11 hero master must stay in ForceMascotLarge.imageset"
        )
        let bytes = try Data(contentsOf: masterURL)
        XCTAssertEqual(
            sha256Hex(bytes),
            approvedR11HeroMasterSHA256,
            "ForceMascotLarge must be byte-identical to the approved R11 160 px hero master"
        )
    }

    // MARK: - Helpers (source-text helpers duplicated from
    // EmptyStateWiringTests / TabGlyphRenderingWiringTests per repo
    // convention: private per test class).

    private func source(_ relativePath: String) -> String {
        let fileURL = packageRoot().appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            XCTFail("Could not read source invariant file: \(fileURL.path): \(error)")
            return ""
        }
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func code(_ source: String) -> String {
        let withoutBlockComments = source.replacingOccurrences(
            of: #"(?s)/\*.*?\*/"#,
            with: "",
            options: .regularExpression
        )
        return withoutBlockComments
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? "" }
            .joined(separator: "\n")
    }

    private func exactBlock(
        _ source: String,
        startingWith marker: String
    ) -> String {
        guard let startRange = source.range(of: marker),
              let openBrace = source.range(
                  of: "{",
                  range: startRange.upperBound..<source.endIndex
              )
        else {
            XCTFail("Missing source invariant block: \(marker)")
            return ""
        }
        var depth = 0
        var cursor = openBrace.lowerBound
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[startRange.lowerBound...cursor])
                }
            default: break
            }
            cursor = source.index(after: cursor)
        }
        XCTFail("Unclosed source invariant block: \(marker)")
        return ""
    }

    private func countOccurrences(_ needle: String, in source: String) -> Int {
        guard !needle.isEmpty else { return 0 }

        var count = 0
        var searchStart = source.startIndex
        while let match = source.range(of: needle, range: searchStart..<source.endIndex) {
            count += 1
            searchStart = match.upperBound
        }
        return count
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
