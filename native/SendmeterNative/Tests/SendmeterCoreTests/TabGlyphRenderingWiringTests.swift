import CryptoKit
import Foundation
import XCTest

/// #875 r2 (reopen): the approved R11 Force glyph read as under-weight / not a
/// clear kangaroo-deadlift-barbell at real tab size even though the rendered
/// SVG was byte-identical to the approved master (ed6dab81...). The fix keeps
/// the R11 artwork frozen and changes the DELIVERED RENDERING: the Force tab
/// presents the approved master as pinned 1x/2x/3x rasters at a 28 pt optical
/// size (vs the 24 pt master canvas), template-tinted by the tab bar.
///
/// The approved master SVG stays in the imageset as an unreferenced
/// provenance anchor so this gate can assert content identity (SHA-256) AND
/// the rendering configuration that carries the fix:
///
///  1. The Force tab wires `Image("ForceMascotTab")` with explicit template
///     rendering (tint axis — an original/baked render would fail tinting).
///  2. The wired imageset's raster content is the approved R11 master at the
///     pinned optical scale (84 px @3x = 28 pt) — a re-raster at the old
///     24 pt scale, different artwork, or a vector fallback entry all fail.
///  3. The Workout tab imageset stays the untouched R16 vector master (r2
///     must not touch Workout and must not cross-assign assets).
///
/// Deterministic raster repro (librsvg; hashes below pin the exact renders):
///   for scale in 1 2 3; do px=$((28 * scale)); rsvg-convert -w $px -h $px \
///     Resources/Assets.xcassets/ForceMascotTab.imageset/r11-force-control-24.svg \
///     -o r11-force-control-28pt@${scale}x.png; done
final class TabGlyphRenderingWiringTests: XCTestCase {
    /// Approved #868/#875 R11 Force 24 px master SHA-256 (issue-verified).
    private let approvedR11MasterSHA256 =
        "ed6dab8109c7e01a1f09a2cfd9225338a304820906cfea84454b4eb3df9cc3ae"
    /// Pinned optical presentation size (points) for the Force tab glyph.
    private let pinnedTabOpticalSizePt = 28
    /// SHA-256 of the pinned approved-master rasters (rsvg-convert renders).
    private let pinnedRasterSHA256: [Int: String] = [
        1: "36fe4198805eea251b27e0d37ff4292131be81a836c99b1721de95d6daf2f36e",
        2: "6ed10994f43d8f1c66048be0f486c1006d6b0d7ea4bab06e019d78b8c243c389",
        3: "3e27e0aded938fa1ab6e18382542b7e4e5343f70b1686ca655cc0f51eaf626fe"
    ]

    func testForceTabWiresTemplateRenderedR11Imageset() {
        let mainTab = exactBlock(
            code(source("Sources/App/SendmeterNativeApp.swift")),
            startingWith: "struct MainTabView: View"
        )
        let normalized = normalizeWhitespace(mainTab)
        // Force tab: the approved mascot imageset, template-tinted.
        XCTAssertTrue(
            normalized.contains(
                "Label { Text(\"Force\") } icon: { Image(\"ForceMascotTab\") .renderingMode(.template) }"
            ),
            "Force tab must render the ForceMascotTab imageset as a template (tint axis)"
        )
        // Never cross-assigned: Force must not use the Workout imageset.
        XCTAssertFalse(
            normalized.contains(
                "Label { Text(\"Force\") } icon: { Image(\"WorkoutMascotTab\")"
            )
        )
    }

    func testForceMascotTabKeepsApprovedR11MasterProvenanceAnchor() {
        let masterURL = imagesetURL().appendingPathComponent("r11-force-control-24.svg")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: masterURL.path),
            "The approved R11 master SVG must stay in the ForceMascotTab imageset as the provenance anchor"
        )
        let bytes = try! Data(contentsOf: masterURL)
        XCTAssertEqual(
            sha256Hex(bytes),
            approvedR11MasterSHA256,
            "The wired tab artwork must be byte-identical to the approved R11 24 px master (asset identity axis)"
        )
    }

    func testForceMascotTabPresentsMasterAtPinnedOpticalRasterScale() {
        let contentsURL = imagesetURL().appendingPathComponent("Contents.json")
        let contents = try! JSONSerialization.jsonObject(
            with: Data(contentsOf: contentsURL)
        ) as! [String: Any]
        let images = contents["images"] as! [[String: Any]]

        // The tab must present pinned rasters of the master — no vector
        // fallback entry that would silently drop back to the 24 pt canvas.
        let scales = images.compactMap { $0["scale"] as? String }.sorted()
        XCTAssertEqual(scales, ["1x", "2x", "3x"])

        for entry in images {
            guard let scaleString = entry["scale"] as? String,
                  let filename = entry["filename"] as? String
            else {
                XCTFail("Malformed imageset entry: \(entry)")
                continue
            }
            let scale = Int(scaleString.dropLast())!
            let data = try! Data(contentsOf: imagesetURL().appendingPathComponent(filename))
            let (width, height) = pngDimensions(data)
            // Size axis: the raster presents the artwork at the pinned optical
            // size, not at the 24 pt master canvas (scale regression catch).
            XCTAssertEqual(
                width, pinnedTabOpticalSizePt * scale,
                "\(filename) must be a \(pinnedTabOpticalSizePt) pt presentation raster at \(scaleString) (\(pinnedTabOpticalSizePt * scale) px)"
            )
            XCTAssertEqual(height, pinnedTabOpticalSizePt * scale)
            // Content axis: the raster is the exact approved-master render.
            XCTAssertEqual(
                sha256Hex(data), pinnedRasterSHA256[scale],
                "\(filename) must be the pinned approved-master raster (content identity axis)"
            )
        }
    }

    func testWorkoutMascotTabRemainsUntouchedR16VectorMaster() {
        // r2 scope fence: the Workout tab asset keeps its exact R16 vector
        // master (no raster swap, no size change) and no cross-assignment.
        let contentsURL = packageRoot().appendingPathComponent(
            "Resources/Assets.xcassets/WorkoutMascotTab.imageset/Contents.json"
        )
        let contents = try! JSONSerialization.jsonObject(
            with: Data(contentsOf: contentsURL)
        ) as! [String: Any]
        let images = contents["images"] as! [[String: Any]]
        XCTAssertEqual(images.count, 1)
        let image = images[0]
        XCTAssertEqual(image["filename"] as? String, "workout-r16-exact-24.svg")
        XCTAssertEqual(image["idiom"] as? String, "universal")
        XCTAssertEqual(
            (image["preserves-vector-representation"] as? Bool) ?? false,
            true,
            "Workout stays a preserved-vector template asset"
        )
    }

    // MARK: - Helpers (source-text helpers duplicated from
    // TabMascotWiringTests per repo convention: private per test class).

    private func imagesetURL() -> URL {
        packageRoot().appendingPathComponent(
            "Resources/Assets.xcassets/ForceMascotTab.imageset"
        )
    }

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

    private func normalizeWhitespace(_ source: String) -> String {
        source
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// PNG width/height from the IHDR chunk (bytes 16-23 after the signature).
    private func pngDimensions(_ data: Data) -> (Int, Int) {
        let bytes = [UInt8](data)
        guard bytes.count >= 24, bytes[0] == 0x89 else { return (0, 0) }
        func be32(_ offset: Int) -> Int {
            Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        }
        return (be32(16), be32(20))
    }
}
