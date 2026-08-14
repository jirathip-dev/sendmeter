import Foundation
import XCTest
@testable import SendLogWatchCore

/// #606: the quarantine-exit breadcrumb ring's pure logic — bounded at
/// capacity, evicts the oldest, survives a fresh store over the same file
/// (relaunch), trims long error messages at write time, and never loses an
/// entry to a "success" (the store has no clearing API at all — retention
/// across success/sign-out/account-switch is the absence of a path, not a
/// path, and the engine tests pin the exit paths against it).
final class QuarantineBreadcrumbTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuarantineBreadcrumbTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var storeURL: URL {
        tempDir.appendingPathComponent("quarantine-exit-history.json")
    }

    private func makeEntry(
        id: UUID = UUID(),
        quarantinedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        exitedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        errorMessage: String? = "fixture failure"
    ) -> QuarantineBreadcrumbEntry {
        QuarantineBreadcrumbEntry(
            id: id,
            reason: .stuckRetrying,
            stage: .session,
            httpStatus: 403,
            postgrestCode: "PGRST301",
            errorMessage: errorMessage,
            attemptCount: QueueRetryPolicy.maxConsecutiveFailures,
            quarantinedAt: quarantinedAt,
            exitedAt: exitedAt
        )
    }

    /// The named acceptance criterion: a recorded exit is readable back
    /// with every header field intact.
    func testARecordedExitIsReadBackWithItsHeaderFields() {
        let entry = makeEntry()
        let store = QuarantineBreadcrumbStore(fileURL: storeURL)

        store.record(entry)

        XCTAssertEqual(store.history(), [entry])
    }

    /// Entries accumulate oldest first — matching the quarantine list's own
    /// oldest-first convention, so the view reverses once for display.
    func testHistoryIsOldestFirst() {
        let store = QuarantineBreadcrumbStore(fileURL: storeURL)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let first = makeEntry(quarantinedAt: base, exitedAt: base)
        let second = makeEntry(quarantinedAt: base.addingTimeInterval(60), exitedAt: base.addingTimeInterval(60))

        store.record(first)
        store.record(second)

        XCTAssertEqual(store.history(), [first, second])
    }

    /// The ring is bounded at `capacity`: recording beyond it evicts the
    /// OLDEST entries, never the newest — the bounded-growth guarantee
    /// (#481 dealt with quarantine records; this must not become a second
    /// unbounded store).
    func testTheRingIsBoundedAndEvictsTheOldest() {
        let store = QuarantineBreadcrumbStore(fileURL: storeURL)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let recorded = (0..<QuarantineBreadcrumbStore.capacity + 3).map { index in
            makeEntry(quarantinedAt: base.addingTimeInterval(Double(index)), exitedAt: base.addingTimeInterval(Double(index)))
        }

        for entry in recorded {
            store.record(entry)
        }

        XCTAssertEqual(store.history().count, QuarantineBreadcrumbStore.capacity)
        let expected = Array(recorded.suffix(QuarantineBreadcrumbStore.capacity))
        XCTAssertEqual(store.history(), expected, "the first three (oldest) must be evicted, the rest retained in order")
    }

    /// A fresh store over the same file sees the entries — the watch
    /// relaunch case, where no in-memory state survives.
    func testHistorySurvivesARelaunch() {
        let entry = makeEntry()
        let firstLife = QuarantineBreadcrumbStore(fileURL: storeURL)
        firstLife.record(entry)

        let relaunched = QuarantineBreadcrumbStore(fileURL: storeURL)

        XCTAssertEqual(relaunched.history(), [entry])
    }

    /// A long server error message is trimmed at write time — the
    /// breadcrumb's one possibly-long field, capped with the same bound the
    /// diagnostics surface already uses, so an entry stays tiny.
    func testErrorMessageIsTruncatedAtWriteTime() {
        let longMessage = String(repeating: "y", count: 300)
        let store = QuarantineBreadcrumbStore(fileURL: storeURL)

        store.record(makeEntry(errorMessage: longMessage))

        XCTAssertEqual(
            store.history()[0].errorMessage,
            QuarantineDiagnostics.truncatedErrorMessage(longMessage),
            "stored, not just displayed, truncated — the file must stay small"
        )
    }

    /// An unreadable history file reads as an empty ring — this store is
    /// diagnostics, not a queued item, so the #287 retain rule does not
    /// apply: the corrupt copy is simply overwritten by the next write.
    func testAnUnreadableHistoryFileStartsEmptyAndIsOverwritten() {
        try? Data("not a breadcrumb ring".utf8).write(to: storeURL, options: .atomic)
        let store = QuarantineBreadcrumbStore(fileURL: storeURL)

        XCTAssertTrue(store.history().isEmpty, "a corrupt ring must not crash or poison the store")

        store.record(makeEntry())
        XCTAssertEqual(store.history().count, 1, "the next write replaces the unreadable file")
        XCTAssertEqual(QuarantineBreadcrumbStore(fileURL: storeURL).history().count, 1)
    }

    /// The on-disk shape is JSON with ISO8601 dates — pinned so the file
    /// format is a committed wire format, not an accident of the encoder.
    func testTheOnDiskShapeRoundTripsThroughJSON() throws {
        let entry = makeEntry()
        let store = QuarantineBreadcrumbStore(fileURL: storeURL)
        store.record(entry)

        let data = try Data(contentsOf: storeURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode([QuarantineBreadcrumbEntry].self, from: data), [entry])
    }

    // MARK: Summary line

    func testFailureSummaryJoinsOnlyTheFieldsThatExist() {
        let entry = makeEntry()
        XCTAssertEqual(
            QuarantineBreadcrumbs.failureSummary(for: entry),
            "stage session, HTTP 403, code PGRST301"
        )
    }

    func testFailureSummaryIsEmptyForATransportFailure() {
        let entry = QuarantineBreadcrumbEntry(
            id: UUID(),
            reason: .stuckRetrying,
            stage: nil,
            httpStatus: nil,
            postgrestCode: nil,
            errorMessage: nil,
            attemptCount: nil,
            quarantinedAt: Date(timeIntervalSince1970: 1_800_000_000),
            exitedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertEqual(
            QuarantineBreadcrumbs.failureSummary(for: entry),
            "",
            "a failure that reached no server has no factual summary to state"
        )
    }

    func testFailureSummaryOmitsNilFieldsIndividually() {
        let entry = QuarantineBreadcrumbEntry(
            id: UUID(),
            reason: .stuckRetrying,
            stage: .climbAttempts,
            httpStatus: nil,
            postgrestCode: "23514",
            errorMessage: nil,
            attemptCount: nil,
            quarantinedAt: Date(timeIntervalSince1970: 1_800_000_000),
            exitedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertEqual(QuarantineBreadcrumbs.failureSummary(for: entry), "stage climbAttempts, code 23514")
    }
}
