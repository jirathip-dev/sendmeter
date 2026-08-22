import XCTest
@testable import SendmeterCore

final class AuthDiagnosticsTests: XCTestCase {
    private func entry(_ category: AuthEventCategory, detail: String? = nil) -> AuthEventEntry {
        AuthEventEntry(category: category, detail: detail, occurredAt: Date())
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
