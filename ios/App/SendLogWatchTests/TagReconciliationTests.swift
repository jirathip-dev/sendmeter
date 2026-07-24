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

// MARK: - TagFetchPolicy (issue #147)
//
// Covers the pure decisions extracted from ForceGaugeView's tag-fetch retry
// loop: the backoff schedule, whether a Progressor connect should restart an
// already-running fetch, and the withTimeout race used to keep a single
// attempt from stalling the "Loading exercises…" spinner for minutes.

final class TagFetchPolicyTests: XCTestCase {
    func testSleepScheduleBetweenAttempts() {
        XCTAssertEqual(TagFetchPolicy.sleepSeconds(afterAttempt: 0), 1.5)
        XCTAssertEqual(TagFetchPolicy.sleepSeconds(afterAttempt: 1), 3.0)
        XCTAssertEqual(TagFetchPolicy.sleepSeconds(afterAttempt: 2), 4.5)
    }

    func testNoTrailingSleepAfterFinalAttempt() {
        // maxAttempts is 4 (indices 0...3) — nothing should sleep after the
        // last attempt, since there's no successor left to wait for. This
        // used to add a pointless ~6s tail before the empty/Retry state
        // could show.
        XCTAssertNil(TagFetchPolicy.sleepSeconds(afterAttempt: TagFetchPolicy.maxAttempts - 1))
    }

    func testShouldRestartOnConnect_inFlightBlocksRestart() {
        // A fetch already mid-retry must not be cancelled/restarted by a
        // connect event — that's exactly what reset the backoff at the
        // worst possible moment (issue #147).
        XCTAssertFalse(TagFetchPolicy.shouldRestartOnConnect(hasTags: false, inFlight: true))
    }

    func testShouldRestartOnConnect_finishedEmptyRestarts() {
        // A fetch that already finished with no tags gets a fresh chance on
        // connect (the auth relay may have settled since).
        XCTAssertTrue(TagFetchPolicy.shouldRestartOnConnect(hasTags: false, inFlight: false))
    }

    func testShouldRestartOnConnect_hasTagsNeverRestarts() {
        XCTAssertFalse(TagFetchPolicy.shouldRestartOnConnect(hasTags: true, inFlight: false))
        XCTAssertFalse(TagFetchPolicy.shouldRestartOnConnect(hasTags: true, inFlight: true))
    }

    func testWithTimeoutReturnsResultWhenFasterThanDeadline() async throws {
        let result = try await withTimeout(seconds: 1) {
            "ok"
        }
        XCTAssertEqual(result, "ok")
    }

    func testWithTimeoutThrowsWhenBodyStalls() async {
        do {
            _ = try await withTimeout(seconds: 0.1) {
                try await Task.sleep(for: .seconds(10))
                return "too slow"
            }
            XCTFail("expected withTimeout to throw")
        } catch is TimeoutError {
            // expected
        } catch {
            XCTFail("expected TimeoutError, got \(error)")
        }
    }

    func testWithTimeoutPropagatesCancellation() async {
        // Cancelling the caller should cancel the race's children too
        // (structured concurrency) rather than swallow the cancellation.
        let task = Task {
            try await withTimeout(seconds: 5) {
                try await Task.sleep(for: .seconds(10))
                return "unreachable"
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation to propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
