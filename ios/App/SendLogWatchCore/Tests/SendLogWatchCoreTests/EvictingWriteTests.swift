import XCTest
import SendLogWatchCore

/// #495 R3: the eviction path's decision logic, tested deterministically —
/// both real defects the #486 re-review found (a proven infinite loop, and
/// evicted recordings deleted with no notice) lived in exactly this control
/// flow, and lived there BECAUSE it had no tests. The filesystem halves
/// (choosing the oldest file, the notice wiring, the real-permissions
/// termination case) are covered in `PendingRecordingQueueTests`
/// (SendLogWatchTests); this covers the loop policy itself, on Linux CI.
final class EvictingWriteTests: XCTestCase {
    func testAWriteThatSucceedsFirstTryEvictsNothing() {
        var writeCalls = 0
        let result = EvictingWrite.run(
            maxEvictions: 5,
            write: { writeCalls += 1 },
            evictOldest: { XCTFail("must not evict when the write succeeds"); return .evicted }
        )
        XCTAssertEqual(result, EvictingWriteResult(persisted: true, evictedCount: 0))
        XCTAssertEqual(writeCalls, 1)
    }

    func testARefusedWriteRetriesAfterEachEvictionUntilItFits() {
        // Simulated disk pressure: the write is refused until two evictions
        // have freed space — the "new recording wins" policy (#486 F5).
        var evicted = 0
        var writeCalls = 0
        let result = EvictingWrite.run(
            maxEvictions: 4,
            write: {
                writeCalls += 1
                if evicted < 2 { throw CocoaError(.fileWriteOutOfSpace) }
            },
            evictOldest: { evicted += 1; return .evicted }
        )
        XCTAssertEqual(result, EvictingWriteResult(persisted: true, evictedCount: 2))
        XCTAssertEqual(writeCalls, 3, "one refused attempt per eviction plus the one that landed")
    }

    func testARefusedEvictionStopsTheLoopImmediately() {
        // #486 re-review R1: the first version looped back after a failed
        // removal, re-selecting the same file forever (proven: 200,001
        // iterations, 59.6s, no exit). A removal failure is information —
        // "this file cannot be freed" — and must stop the loop.
        var writeCalls = 0
        var evictionAttempts = 0
        let result = EvictingWrite.run(
            maxEvictions: 1000,
            write: { writeCalls += 1; throw CocoaError(.fileWriteOutOfSpace) },
            evictOldest: { evictionAttempts += 1; return .evictionRefused }
        )
        XCTAssertEqual(result, EvictingWriteResult(persisted: false, evictedCount: 0))
        XCTAssertEqual(writeCalls, 1, "must not keep re-attempting the write after a refused eviction")
        XCTAssertEqual(evictionAttempts, 1, "must not keep re-selecting the unremovable file")
    }

    func testRunningOutOfFilesToEvictReportsTheRefusalHonestly() {
        var evictionsLeft = 2
        let result = EvictingWrite.run(
            maxEvictions: 2,
            write: { throw CocoaError(.fileWriteOutOfSpace) },
            evictOldest: {
                guard evictionsLeft > 0 else { return .nothingLeftToEvict }
                evictionsLeft -= 1
                return .evicted
            }
        )
        // Everything evictable was destroyed and the write still failed:
        // `persisted: false` is what routes the caller to the direct-upload
        // fallback, and the nonzero eviction count is what the caller must
        // report (#264) — those files are gone regardless of this outcome.
        XCTAssertEqual(result, EvictingWriteResult(persisted: false, evictedCount: 2))
    }

    func testTheIterationBoundHoldsEvenIfEvictionAlwaysClaimsSuccess() {
        // The R1 backstop: even a pathological callback that reports
        // `.evicted` forever (a future silent-failure regression) cannot
        // make the loop run away — it is bounded by the file count taken
        // when it started.
        var writeCalls = 0
        var evictions = 0
        let result = EvictingWrite.run(
            maxEvictions: 3,
            write: { writeCalls += 1; throw CocoaError(.fileWriteOutOfSpace) },
            evictOldest: { evictions += 1; return .evicted }
        )
        XCTAssertEqual(result.persisted, false)
        XCTAssertEqual(writeCalls, 4, "0...maxEvictions attempts, then stop — never unbounded")
        XCTAssertEqual(evictions, 4)
    }

    func testANegativeBoundStillAllowsTheOneWriteAttempt() {
        var writeCalls = 0
        let result = EvictingWrite.run(
            maxEvictions: -3,
            write: { writeCalls += 1 },
            evictOldest: { .nothingLeftToEvict }
        )
        XCTAssertEqual(result, EvictingWriteResult(persisted: true, evictedCount: 0))
        XCTAssertEqual(writeCalls, 1)
    }
}
