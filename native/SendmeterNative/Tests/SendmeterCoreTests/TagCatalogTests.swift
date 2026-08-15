import XCTest
@testable import SendmeterCore

/// Pins the tag-registry logic (SL-92, #631) — the exercise list derivation,
/// and the rename/hide state transitions the manager UI shows. The DB side
/// (RPC semantics) is matched to `rename_tindeq_tag`: repoint every
/// recording, drop the old registry row, and when the new name already has a
/// row its hidden state wins.
final class TagCatalogTests: XCTestCase {
    private func recording(_ tag: String) -> TindeqRecording {
        TindeqRecording(
            id: UUID(),
            recordedAt: Date(),
            durationMilliseconds: 1_000,
            peakKilograms: 20,
            averageKilograms: 15,
            sampleCount: 1,
            note: "",
            tag: tag,
            side: .unspecified,
            groupID: nil
        )
    }

    private func metadata(_ name: String, hidden: Bool) -> TagMetadata {
        TagMetadata(name: name, hidden: hidden)
    }

    func testEntriesDeriveCountsAndHiddenFlags() {
        let entries = TagCatalog.entries(
            recordings: [recording("half crimp"), recording("half crimp"), recording("sloper"), recording("")],
            metadata: [metadata("half crimp", hidden: true)]
        )
        XCTAssertEqual(entries.count, 2)
        let crimp = entries.first { $0.name == "half crimp" }
        XCTAssertEqual(crimp?.count, 2)
        XCTAssertTrue(crimp?.hidden == true)
        let sloper = entries.first { $0.name == "sloper" }
        XCTAssertEqual(sloper?.count, 1)
        XCTAssertFalse(sloper?.hidden == true)
    }

    func testEntriesSortCaseInsensitivelyByName() {
        let entries = TagCatalog.entries(
            recordings: [recording("Sloper"), recording("half crimp")],
            metadata: []
        )
        XCTAssertEqual(entries.map(\.name), ["half crimp", "Sloper"])
    }

    func testVisibleNamesExcludesHidden() {
        let entries = TagCatalog.entries(
            recordings: [recording("a"), recording("b"), recording("c")],
            metadata: [metadata("b", hidden: true)]
        )
        XCTAssertEqual(TagCatalog.visibleNames(entries), ["a", "c"])
    }

    func testHiddenNamesFromMetadata() {
        let hidden = TagCatalog.hiddenNames([
            metadata("a", hidden: true),
            metadata("b", hidden: false),
        ])
        XCTAssertEqual(hidden, ["a"])
    }

    // MARK: Rename transitions

    func testRenameRepointsCountsAndClearsHidden() {
        let entries = TagCatalog.entries(
            recordings: [recording("old"), recording("old"), recording("other")],
            metadata: [metadata("old", hidden: true)]
        )
        let renamed = TagCatalog.applyingRename(entries, from: "old", to: "new")
        XCTAssertNil(renamed.first { $0.name == "old" })
        let merged = renamed.first { $0.name == "new" }
        XCTAssertEqual(merged?.count, 2)
        // A rename into a brand-new name becomes visible again (the RPC
        // drops the old registry row).
        XCTAssertFalse(merged?.hidden == true)
        XCTAssertEqual(renamed.count, 2)
    }

    func testRenameMergesCountsAndKeepsTargetHidden() {
        let entries = TagCatalog.entries(
            recordings: [recording("a"), recording("b"), recording("b")],
            metadata: [metadata("b", hidden: true)]
        )
        let renamed = TagCatalog.applyingRename(entries, from: "a", to: "b")
        XCTAssertNil(renamed.first { $0.name == "a" })
        let merged = renamed.first { $0.name == "b" }
        XCTAssertEqual(merged?.count, 3)
        // The surviving row's hidden state wins.
        XCTAssertTrue(merged?.hidden == true)
        XCTAssertEqual(renamed.count, 1)
    }

    func testRenameToSameNameIsNoOp() {
        let entries = TagCatalog.entries(recordings: [recording("a")], metadata: [])
        XCTAssertEqual(TagCatalog.applyingRename(entries, from: "a", to: "a"), entries)
    }

    func testRenameToEmptyIsNoOp() {
        let entries = TagCatalog.entries(recordings: [recording("a")], metadata: [])
        XCTAssertEqual(TagCatalog.applyingRename(entries, from: "a", to: "   "), entries)
    }

    func testRenameUnknownSourceIsNoOp() {
        let entries = TagCatalog.entries(recordings: [recording("a")], metadata: [])
        XCTAssertEqual(TagCatalog.applyingRename(entries, from: "missing", to: "b"), entries)
    }

    // MARK: Hide transitions

    func testHideAndUnhideToggleFlagOnly() {
        let entries = TagCatalog.entries(recordings: [recording("a")], metadata: [])
        let hidden = TagCatalog.applyingHidden(entries, name: "a", hidden: true)
        XCTAssertTrue(hidden.first?.hidden == true)
        XCTAssertEqual(hidden.first?.count, 1)
        let shown = TagCatalog.applyingHidden(hidden, name: "a", hidden: false)
        XCTAssertFalse(shown.first?.hidden == true)
        // Recordings are never touched — the count survives both ways.
        XCTAssertEqual(shown.first?.count, 1)
    }

    func testHideUnknownNameIsNoOp() {
        let entries = TagCatalog.entries(recordings: [recording("a")], metadata: [])
        XCTAssertEqual(TagCatalog.applyingHidden(entries, name: "missing", hidden: true), entries)
    }

    func testTagMetadataCodableRoundTrip() throws {
        let metadata = TagMetadata(name: "half crimp", hidden: true)
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(TagMetadata.self, from: data)
        XCTAssertEqual(decoded, metadata)
    }
}
