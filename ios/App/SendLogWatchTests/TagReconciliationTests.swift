import XCTest
@testable import SendLogWatch_Watch_App

final class TagReconciliationTests: XCTestCase {
    func testEmptyTagNeverClears() {
        // No selection yet — nothing to reconcile.
        XCTAssertFalse(TagReconciliation.shouldClearStaleTag("", visibleTags: ["Crimps"]))
        XCTAssertFalse(TagReconciliation.shouldClearStaleTag("", visibleTags: []))
    }

    func testVisibleTagIsKept() {
        XCTAssertFalse(TagReconciliation.shouldClearStaleTag("Crimps", visibleTags: ["Crimps", "Slopers"]))
    }

    func testHiddenTagIsCleared() {
        // "Crimps" no longer comes back from fetchRecentTindeqTags because
        // it's hidden via the tindeq_tags registry (SL-92).
        XCTAssertTrue(TagReconciliation.shouldClearStaleTag("Crimps", visibleTags: ["Slopers"]))
    }

    func testRenamedTagIsCleared() {
        // "Crimps" was renamed to "Half Crimps" — the old name never appears
        // in the distinct-tag list again since the rename repoints every
        // recording, so the persisted default is stale.
        XCTAssertTrue(TagReconciliation.shouldClearStaleTag("Crimps", visibleTags: ["Half Crimps"]))
    }

    func testAllTagsGoneClearsSelection() {
        // Pure-function behavior only: the caller (loadTags) never reconciles
        // against an empty list, since an RLS-empty unauthenticated select is
        // indistinguishable from the SL-75 auth race.
        XCTAssertTrue(TagReconciliation.shouldClearStaleTag("Crimps", visibleTags: []))
    }
}
