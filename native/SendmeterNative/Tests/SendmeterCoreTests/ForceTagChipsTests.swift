import XCTest
@testable import SendmeterCore

/// #750: pins the compact Force recording-context exercise-chip presentation
/// (the native sibling of Capacitor's `TagSideEditor` chip list).
final class ForceTagChipsTests: XCTestCase {
    func testUniqueTagsDropsDuplicateAndBlankNames() {
        let list = TagChipList(
            allTags: ["FDP", "FDP", "  ", "Sloper", "Crimp"],
            activeTag: ""
        )
        XCTAssertEqual(list.uniqueTags, ["FDP", "Sloper", "Crimp"])
    }

    func testActiveTagBeyondVisiblePrefixAlwaysAppears() {
        let tags = (0..<10).map { "Exercise \($0)" }
        let list = TagChipList(allTags: tags, activeTag: "Exercise 9")
        XCTAssertEqual(list.visibleTags.count, 9)
        XCTAssertEqual(Array(list.visibleTags.prefix(8)), Array(tags.prefix(8)))
        XCTAssertEqual(list.visibleTags.last, "Exercise 9")
        XCTAssertEqual(list.hiddenCount, 1)
    }

    func testUnknownActiveTagIsShownFirstAndImmediatelyVisible() {
        let tags = (0..<10).map { "Exercise \($0)" }
        let list = TagChipList(allTags: tags, activeTag: "Brand New")
        XCTAssertEqual(list.uniqueTags.first, "Brand New")
        XCTAssertEqual(list.visibleTags.first, "Brand New")
        XCTAssertFalse(list.visibleTags.contains("Exercise 8"))
        XCTAssertEqual(list.hiddenCount, 3)
    }

    func testHiddenCountIsZeroWhenNothingIsHidden() {
        let tags = (0..<8).map { "Exercise \($0)" }
        let list = TagChipList(allTags: tags, activeTag: "Exercise 7")
        XCTAssertEqual(list.visibleTags, tags)
        XCTAssertEqual(list.hiddenCount, 0)
    }

    func testRevealAllShowsEveryTagAndClearsHiddenCount() {
        let tags = (0..<14).map { "Exercise \($0)" }
        let collapsed = TagChipList(allTags: tags, activeTag: "Exercise 13")
        XCTAssertGreaterThan(collapsed.hiddenCount, 0)

        let revealed = collapsed.showingAll()
        XCTAssertTrue(revealed.showsAll)
        XCTAssertEqual(revealed.visibleTags, tags)
        XCTAssertEqual(revealed.hiddenCount, 0)
    }

    func testEmptyActiveTagDoesNotInventAChip() {
        let tags = (0..<12).map { "Exercise \($0)" }
        let list = TagChipList(allTags: tags, activeTag: "  ")
        XCTAssertEqual(list.uniqueTags, tags)
        XCTAssertEqual(list.visibleTags, Array(tags.prefix(8)))
        XCTAssertEqual(list.hiddenCount, 4)
    }
}
