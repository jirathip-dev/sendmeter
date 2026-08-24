import XCTest
@testable import SendmeterCore

final class AuthDiagnosticsTests: XCTestCase {
    private func entry(
        _ category: AuthEventCategory,
        detail: String? = nil,
        at date: Date = Date()
    ) -> AuthEventEntry {
        AuthEventEntry(category: category, detail: detail, occurredAt: date)
    }

    func testUserFacingClassificationPinsRefreshAndSignOutAsDiagnostic() {
        XCTAssertTrue(AuthEventCategory.signIn.isUserFacingSummary)
        XCTAssertTrue(AuthEventCategory.failure.isUserFacingSummary)
        XCTAssertFalse(AuthEventCategory.refresh.isUserFacingSummary)
        XCTAssertFalse(AuthEventCategory.signOut.isUserFacingSummary)
    }

    func testSummaryIsEmptyForEmptyRing() {
        let summary = AuthDiagnostics.summary(of: [])
        XCTAssertNil(summary.lastSignIn)
        XCTAssertNil(summary.lastFailure)
    }

    func testSummaryPicksLatestSignInAndFailureByTimestamp() {
        let olderSignIn = entry(.signIn, detail: "Session restored at launch", at: Date(timeIntervalSince1970: 100))
        let newerSignIn = entry(.signIn, detail: "Session established", at: Date(timeIntervalSince1970: 300))
        let olderFailure = entry(.failure, detail: "The request timed out.", at: Date(timeIntervalSince1970: 200))
        let newerFailure = entry(.failure, detail: "Session refresh failed: JWT expired", at: Date(timeIntervalSince1970: 400))
        // Deliberately out of order: summary is timestamp-based, not order-based.
        let history = [newerFailure, olderSignIn, olderFailure, newerSignIn]

        let summary = AuthDiagnostics.summary(of: history)
        XCTAssertEqual(summary.lastSignIn?.detail, newerSignIn.detail)
        XCTAssertEqual(summary.lastSignIn?.occurredAt, newerSignIn.occurredAt)
        XCTAssertEqual(summary.lastFailure?.detail, newerFailure.detail)
        XCTAssertEqual(summary.lastFailure?.occurredAt, newerFailure.occurredAt)
    }

    func testSummaryOmitsRefreshAndSignOutNoise() {
        let latestRefresh = entry(.refresh, at: Date(timeIntervalSince1970: 500))
        let signOut = entry(.signOut, at: Date(timeIntervalSince1970: 600))
        let failure = entry(.failure, at: Date(timeIntervalSince1970: 100))

        let summary = AuthDiagnostics.summary(of: [failure, latestRefresh, signOut])
        XCTAssertNil(summary.lastSignIn)
        XCTAssertEqual(summary.lastFailure?.occurredAt, failure.occurredAt)
    }

    func testRecordsOldestFirst() {
        let store = AuthDiagnosticsStore(fileURL: nil)
        store.record(entry(.signIn, detail: "first"))
        store.record(entry(.refresh, detail: "second"))

        let history = store.history()
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.first?.category, .signIn)
        XCTAssertEqual(history.last?.category, .refresh)
    }

    func testCapacityEvictionDropsOldest() {
        let store = AuthDiagnosticsStore(fileURL: nil)
        // Record capacity + 5, so the oldest five must be evicted.
        for i in 0..<(AuthDiagnosticsStore.capacity + 5) {
            store.record(entry(.failure, detail: "event \(i)"))
        }

        let history = store.history()
        XCTAssertEqual(history.count, AuthDiagnosticsStore.capacity)
        XCTAssertEqual(history.first?.detail, "event 5")
        XCTAssertEqual(history.last?.detail, "event \(AuthDiagnosticsStore.capacity + 4)")
    }

    func testCoversAllFourCategories() {
        let store = AuthDiagnosticsStore(fileURL: nil)
        store.record(entry(.signIn))
        store.record(entry(.refresh))
        store.record(entry(.signOut))
        store.record(entry(.failure))

        let categories = Set(store.history().map(\.category))
        XCTAssertEqual(categories, Set(AuthEventCategory.allCases))
    }

    func testDetailIsTrimmedAtWriteTime() {
        let store = AuthDiagnosticsStore(fileURL: nil)
        let long = String(repeating: "x", count: 500)
        store.record(entry(.failure, detail: long))

        XCTAssertEqual(store.history().first?.detail?.count, AuthDiagnostics.detailDisplayLimit)
        XCTAssertTrue(store.history().first?.detail?.hasSuffix("…") ?? false)
    }

    func testPersistenceRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("authd-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = AuthDiagnosticsStore(fileURL: url)
        writer.record(entry(.signIn, detail: "persisted"))
        writer.record(entry(.signOut))

        let reader = AuthDiagnosticsStore(fileURL: url)
        let history = reader.history()
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].category, .signIn)
        XCTAssertEqual(history[0].detail, "persisted")
        XCTAssertEqual(history[1].category, .signOut)
    }

    func testCorruptFileReadsAsEmptyRing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("authd-corrupt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try "not json".data(using: .utf8)!.write(to: url)

        let store = AuthDiagnosticsStore(fileURL: url)
        XCTAssertTrue(store.history().isEmpty)
    }
}
