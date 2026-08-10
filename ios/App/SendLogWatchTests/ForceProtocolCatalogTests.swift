import Foundation
import SendLogWatchCore
import XCTest
@testable import SendLogWatch_Watch_App

private enum ForceProtocolCatalogTestError: Error {
    case offline
}

/// Mirrors the real "JWT expired" text observed on-device (#536) — the exact
/// wording `Repo.fetchTindeqPresets()` surfaces when the relayed access
/// token has expired.
private struct ForceProtocolCatalogTestAuthError: LocalizedError {
    var errorDescription: String? { "JWT expired" }
}

/// Thread-safe mutable inputs for the injected catalog seams. The fetch runs
/// inside `withTimeout`'s task group, so the test provider must be Sendable even
/// though each test itself is main-actor isolated.
private final class ForceProtocolCatalogTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedUserId: UUID?
    private var storedProtocols: [WatchForceProtocol] = []
    private var isOffline = false
    private var pendingError: Error?

    init(userId: UUID) {
        storedUserId = userId
    }

    var userId: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return storedUserId
    }

    func setUserId(_ userId: UUID?) {
        lock.lock()
        storedUserId = userId
        lock.unlock()
    }

    func setProtocols(_ protocols: [WatchForceProtocol]) {
        lock.lock()
        storedProtocols = protocols
        lock.unlock()
    }

    func setOffline(_ offline: Bool) {
        lock.lock()
        isOffline = offline
        lock.unlock()
    }

    func setPendingError(_ error: Error?) {
        lock.lock()
        pendingError = error
        lock.unlock()
    }

    func fetch() throws -> [WatchForceProtocol] {
        lock.lock()
        defer { lock.unlock() }
        if let pendingError { throw pendingError }
        if isOffline { throw ForceProtocolCatalogTestError.offline }
        return storedProtocols
    }
}

@MainActor
final class ForceProtocolCatalogTests: XCTestCase {
    func testSwitchingAccountsClearsRowsBeforeTheNewAccountRefreshes() async {
        let defaults = makeDefaults()
        let accountA = UUID()
        let accountB = UUID()
        let protocolA = makeProtocol(id: "account-a-protocol", name: "A protocol")
        let protocolB = makeProtocol(id: "account-b-protocol", name: "B protocol")
        let state = ForceProtocolCatalogTestState(userId: accountA)
        state.setProtocols([protocolA])
        let catalog = makeCatalog(defaults: defaults, state: state)

        await catalog.refresh()
        catalog.select(protocolA)
        XCTAssertEqual(catalog.myProtocols, [protocolA])
        XCTAssertEqual(catalog.selected.id, protocolA.id)

        // AuthManager stores B's relay before publishing the auth state. This
        // direct call proves the catalog's synchronous safety boundary itself,
        // before a new network response can arrive.
        state.setUserId(accountB)
        catalog.synchronizeAccountScope()
        XCTAssertEqual(catalog.myProtocols, [])
        XCTAssertEqual(catalog.selected, .movementStarter)
        XCTAssertEqual(catalog.status, .loading)
        XCTAssertFalse(catalog.allProtocols.contains(protocolA))

        state.setProtocols([protocolB])
        await catalog.refresh()
        XCTAssertEqual(catalog.myProtocols, [protocolB])
        XCTAssertFalse(catalog.allProtocols.contains(protocolA))
        XCTAssertEqual(catalog.selected, .movementStarter)
    }

    func testSameAccountOfflineRefreshKeepsCachedRowsAndSelection() async {
        let defaults = makeDefaults()
        let account = UUID()
        let protocolValue = makeProtocol(id: "same-account-protocol", name: "Saved protocol")
        let state = ForceProtocolCatalogTestState(userId: account)
        state.setProtocols([protocolValue])
        let catalog = makeCatalog(defaults: defaults, state: state)

        await catalog.refresh()
        catalog.select(protocolValue)
        state.setOffline(true)

        await catalog.refresh()

        XCTAssertEqual(catalog.status, .cached)
        XCTAssertEqual(catalog.myProtocols, [protocolValue])
        XCTAssertEqual(catalog.selected.id, protocolValue.id)

        // Relaunching under the same stable identity must restore the same
        // account's cache and selection even before a request succeeds.
        let relaunched = makeCatalog(defaults: defaults, state: state)
        XCTAssertEqual(relaunched.myProtocols, [protocolValue])
        XCTAssertEqual(relaunched.selected.id, protocolValue.id)
        XCTAssertEqual(relaunched.status, .cached)
    }

    /// Regression for #536: a real "JWT expired" refresh failure must never
    /// reach the picker as raw text. With saved rows present the catalog
    /// stays usable (`.cached`), the title says so, and `errorMessage`
    /// carries only the recovery action — never a repeated cache claim
    /// (review finding 2).
    func testExpiredTokenFailureWithCachedSnapshotShowsProductCopyOnly() async throws {
        let defaults = makeDefaults()
        let account = UUID()
        let protocolValue = makeProtocol(id: "cached-protocol", name: "Cached protocol")
        let state = ForceProtocolCatalogTestState(userId: account)
        state.setProtocols([protocolValue])
        let catalog = makeCatalog(defaults: defaults, state: state)

        await catalog.refresh()
        XCTAssertEqual(catalog.status, .fresh)

        state.setPendingError(ForceProtocolCatalogTestAuthError())
        await catalog.refresh()

        XCTAssertEqual(catalog.status, .cached)
        XCTAssertEqual(catalog.myProtocols, [protocolValue])
        XCTAssertEqual(catalog.syncBannerTitle, "Showing saved protocols")
        let message = try XCTUnwrap(catalog.errorMessage)
        XCTAssertEqual(message, "Open Sendmeter on iPhone to refresh.")
        assertNoRawTechnicalWording(message)
        assertNoRawTechnicalWording(catalog.syncBannerTitle)
    }

    /// Same failure, but with nothing cached yet — the catalog has no rows to
    /// fall back to, so `.failed` is correct. #536 review round 2 finding A:
    /// no successful fetch has EVER completed for this account, so the title
    /// must NOT claim "No saved protocols yet" (that would assert the count
    /// is confirmed zero, when it's actually unknown — the account could
    /// have a dozen real saved protocols the watch just can't confirm right
    /// now). It must say the sync itself failed, distinct from the
    /// legitimately-empty-cache case in the test below.
    func testExpiredTokenFailureWithoutCachedSnapshotShowsProductCopyOnly() async throws {
        let defaults = makeDefaults()
        let account = UUID()
        let state = ForceProtocolCatalogTestState(userId: account)
        state.setPendingError(ForceProtocolCatalogTestAuthError())
        let catalog = makeCatalog(defaults: defaults, state: state)

        await catalog.refresh()

        XCTAssertEqual(catalog.status, .failed)
        XCTAssertEqual(catalog.myProtocols, [])
        XCTAssertEqual(catalog.syncBannerTitle, "Couldn\u{2019}t sync protocols")
        XCTAssertFalse(catalog.syncBannerTitle.lowercased().contains("saved"))
        let message = try XCTUnwrap(catalog.errorMessage)
        XCTAssertEqual(message, "Open Sendmeter on iPhone to refresh.")
        assertNoRawTechnicalWording(message)
        assertNoRawTechnicalWording(catalog.syncBannerTitle)
    }

    /// Regression for #536 review finding 1: `persistCache()` runs on every
    /// successful fetch including an empty one, so `hasCachedSnapshot ==
    /// true` (a cache write happened) does not imply there are rows to show.
    /// Seeds that exact on-disk shape directly (a live empty-but-authenticated
    /// refresh needs a real relayed session this test harness doesn't control)
    /// and asserts a later auth failure does NOT claim "Showing saved
    /// protocols" — there is nothing saved to show. Unlike the never-synced
    /// test above, THIS state genuinely does know the count is zero (a prior
    /// successful fetch confirmed it), so "No saved protocols yet" is
    /// correct here and must read differently from "Couldn't sync
    /// protocols" (#536 review round 2 finding A).
    func testExpiredTokenFailureWithEmptyPersistedCacheNeverClaimsSavedRows() async throws {
        let defaults = makeDefaults()
        let account = UUID()
        seedEmptyCache(defaults: defaults, userId: account)
        let state = ForceProtocolCatalogTestState(userId: account)
        state.setPendingError(ForceProtocolCatalogTestAuthError())
        let catalog = makeCatalog(defaults: defaults, state: state)

        XCTAssertTrue(catalog.hasCachedSnapshot)
        XCTAssertEqual(catalog.myProtocols, [])
        XCTAssertEqual(catalog.status, .cached)

        await catalog.refresh()

        XCTAssertEqual(catalog.status, .cached)
        XCTAssertEqual(catalog.myProtocols, [])
        XCTAssertEqual(catalog.syncBannerTitle, "No saved protocols yet")
        XCTAssertNotEqual(catalog.syncBannerTitle, "Couldn\u{2019}t sync protocols")
        let message = try XCTUnwrap(catalog.errorMessage)
        XCTAssertEqual(message, "Open Sendmeter on iPhone to refresh.")
        assertNoRawTechnicalWording(message)
        assertNoRawTechnicalWording(catalog.syncBannerTitle)
    }

    /// #536 review round 2 finding A ("worse" case): an anonymous/RLS empty
    /// response with no cache sets `status = .failed` with the message
    /// "Waiting for your iPhone to finish signing in." — the code *knows*
    /// the request was unauthenticated, i.e. the strongest possible evidence
    /// the protocol count is unknown, not confirmed zero. The title must
    /// still say the sync failed, not that there are no saved protocols.
    func testUnauthenticatedEmptyResponseWithoutCacheDoesNotClaimZeroProtocols() async throws {
        let defaults = makeDefaults()
        let account = UUID()
        let state = ForceProtocolCatalogTestState(userId: account)
        state.setProtocols([])
        let catalog = makeCatalog(defaults: defaults, state: state)

        await catalog.refresh()

        XCTAssertEqual(catalog.status, .failed)
        XCTAssertEqual(catalog.myProtocols, [])
        XCTAssertEqual(catalog.syncBannerTitle, "Couldn\u{2019}t sync protocols")
        XCTAssertFalse(catalog.syncBannerTitle.lowercased().contains("saved"))
        let message = try XCTUnwrap(catalog.errorMessage)
        XCTAssertEqual(message, "Waiting for your iPhone to finish signing in.")
        assertNoRawTechnicalWording(message)
        assertNoRawTechnicalWording(catalog.syncBannerTitle)
    }

    /// Writes the exact on-disk shape `ForceProtocolCatalog.persistCache()`
    /// would have written for a legitimately-empty catalog — same key
    /// scheme (`forceProtocolCatalog.v2.cache.<uuid>`), same `{protocols,
    /// fetchedAt}` shape (the private `Cache` type isn't visible here, but
    /// `Codable` matches structurally, not nominally).
    private func seedEmptyCache(defaults: UserDefaults, userId: UUID) {
        struct SeedCache: Codable {
            let protocols: [WatchForceProtocol]
            let fetchedAt: Date
        }
        let data = try! JSONEncoder().encode(SeedCache(protocols: [], fetchedAt: Date()))
        defaults.set(data, forKey: "forceProtocolCatalog.v2.cache.\(userId.uuidString.lowercased())")
    }

    /// Kept in sync with `ForceProtocolSyncCopyTests.rawTechnicalTerms` in
    /// `SendLogWatchCoreTests` (#536 review finding 7) — the two suites must
    /// not silently diverge on what counts as a leak.
    private func assertNoRawTechnicalWording(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let lowered = message.lowercased()
        let rawTerms = [
            "jwt", "jws", "postgrest", "pgrst", "http", "supabase", "row-level security",
            "401", "403", "status code", "expired", "token", "unauthorized", "denied",
            "authentication", "api key", "sqlstate"
        ]
        for term in rawTerms {
            XCTAssertFalse(
                lowered.contains(term),
                "product copy leaked raw technical wording \"\(term)\": \(message)",
                file: file,
                line: line
            )
        }
    }

    func testSelectionIsStoredPerAccountAndNeverCrossesAccounts() async {
        let defaults = makeDefaults()
        let accountA = UUID()
        let accountB = UUID()
        let protocolA = makeProtocol(id: "selection-a", name: "Selection A")
        let protocolB = makeProtocol(id: "selection-b", name: "Selection B")
        let state = ForceProtocolCatalogTestState(userId: accountA)
        state.setProtocols([protocolA])
        let catalog = makeCatalog(defaults: defaults, state: state)

        await catalog.refresh()
        catalog.select(protocolA)

        state.setUserId(accountB)
        state.setProtocols([protocolB])
        catalog.synchronizeAccountScope()
        XCTAssertEqual(catalog.selected, .movementStarter)
        await catalog.refresh()
        catalog.select(protocolB)
        XCTAssertEqual(catalog.selected.id, protocolB.id)

        state.setUserId(accountA)
        catalog.synchronizeAccountScope()
        XCTAssertEqual(catalog.myProtocols, [protocolA])
        XCTAssertEqual(catalog.selected.id, protocolA.id)
        XCTAssertFalse(catalog.allProtocols.contains(protocolB))

        state.setUserId(accountB)
        catalog.synchronizeAccountScope()
        XCTAssertEqual(catalog.myProtocols, [protocolB])
        XCTAssertEqual(catalog.selected.id, protocolB.id)
        XCTAssertFalse(catalog.allProtocols.contains(protocolA))
    }

    private func makeCatalog(
        defaults: UserDefaults,
        state: ForceProtocolCatalogTestState
    ) -> ForceProtocolCatalog {
        ForceProtocolCatalog(
            defaults: defaults,
            accountIdProvider: { state.userId },
            fetchProtocols: { try state.fetch() }
        )
    }

    private func makeProtocol(id: String, name: String) -> WatchForceProtocol {
        WatchForceProtocol(
            id: id,
            name: name,
            holdS: 10,
            reps: 2,
            sets: 1,
            restRepsS: 0,
            restSetsS: 0,
            mode: .hold
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "ForceProtocolCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
