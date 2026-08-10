import Foundation
import Observation
import OSLog
import SendLogWatchCore

/// Read-only Force protocol catalog for watchOS. The phone/web app owns
/// authoring; the watch only selects rows that already exist there.
///
/// A particularly subtle failure mode is an RLS-protected select made while
/// the phone is still relaying a token. PostgREST can answer that unauthenticated
/// request with a successful empty array, rather than an HTTP error. An empty
/// response is therefore destructive only when the watch currently has a
/// usable relayed session; otherwise the last cache remains intact and the
/// retry path gets another chance after the relay settles.
@MainActor
@Observable
final class ForceProtocolCatalog {
    enum Status: Equatable {
        case loading
        case fresh
        case empty
        case cached
        case failed
    }

    private struct Cache: Codable {
        let protocols: [WatchForceProtocol]
        let fetchedAt: Date
    }

    // The old v1 keys were global to the watch install. They are deliberately
    // not migrated: there is no owner identity in those values, so adopting
    // them after an account switch would be an account-data leak. Every value
    // written by this catalog is scoped to the stable relayed user id below.
    private static let cacheKeyPrefix = "forceProtocolCatalog.v2.cache."
    private static let selectedKeyPrefix = "forceProtocolCatalog.v2.selected."
    private static let maxAttempts = 3
    private static let perAttemptTimeoutSeconds: Double = 6
    private static let retryDelaysMs: [UInt64] = [250, 750]

    private static let log = Logger(
        subsystem: "com.jirathip.sendlog.watchkitapp", category: "forceProtocolCatalog"
    )

    private let defaults: UserDefaults
    @ObservationIgnored private let accountIdProvider: @Sendable () -> UUID?
    @ObservationIgnored private let fetchProtocols: @Sendable () async throws -> [WatchForceProtocol]
    @ObservationIgnored private var scopedUserId: UUID?
    @ObservationIgnored private var didSynchronizeAccountScope = false
    private(set) var myProtocols: [WatchForceProtocol] = []
    private(set) var fetchedAt: Date?
    private(set) var status: Status = .loading
    private(set) var errorMessage: String?
    private(set) var selectedId: String
    private var refreshGeneration = 0

    var suggested: [WatchForceProtocol] { [.movementStarter] }

    var selected: WatchForceProtocol {
        synchronizeAccountScope()
        return allProtocols.first { $0.id == selectedId } ?? .movementStarter
    }

    var allProtocols: [WatchForceProtocol] {
        synchronizeAccountScope()
        return suggested + myProtocols
    }

    var hasCachedSnapshot: Bool {
        synchronizeAccountScope()
        return fetchedAt != nil
    }

    var statusText: String? {
        synchronizeAccountScope()
        switch status {
        case .loading:
            return "Syncing protocols…"
        case .fresh:
            return nil
        case .empty:
            return "No saved protocols yet"
        case .cached:
            // No default text: a cold launch from cache reaches `.cached`
            // before any refresh has been attempted, so there is nothing
            // honest to say yet beyond the title (#536 review finding 9).
            return errorMessage
        case .failed:
            return errorMessage ?? ForceProtocolSyncCopy.message(for: .unknown)
        }
    }

    /// The `.cached`/`.failed` banner title, from the single Core source of
    /// truth (`ForceProtocolSyncCopy.title(for:)`, #536 review round 2
    /// finding B — this used to re-declare the same literals here).
    ///
    /// `.failed` must NOT reuse the empty-rows title: it means no successful
    /// fetch has ever completed for this account, so the count is genuinely
    /// *unknown*, not confirmed zero — an account with a stale token but 12
    /// real saved protocols would otherwise render "No saved protocols yet",
    /// a false factual claim from a failed request (#536 review round 2
    /// finding A). Only `.cached` (a prior successful fetch, possibly empty,
    /// is still on screen) may claim a count either way.
    var syncBannerTitle: String {
        synchronizeAccountScope()
        let rows: ForceProtocolSyncCopy.RowsState
        if !myProtocols.isEmpty {
            rows = .cachedWithRows
        } else if status == .cached {
            rows = .cachedEmpty
        } else {
            rows = .neverSynced
        }
        return ForceProtocolSyncCopy.title(for: rows)
    }

    init(
        defaults: UserDefaults = .standard,
        accountIdProvider: @escaping @Sendable () -> UUID? = { WatchSessionStore.shared.userId },
        fetchProtocols: @escaping @Sendable () async throws -> [WatchForceProtocol] = {
            try await Repo.fetchTindeqPresets()
        }
    ) {
        self.defaults = defaults
        self.accountIdProvider = accountIdProvider
        self.fetchProtocols = fetchProtocols
        scopedUserId = accountIdProvider()
        selectedId = WatchForceProtocol.movementStarter.id
        didSynchronizeAccountScope = true
        restoreCache(for: scopedUserId)
    }

    func select(_ protocolValue: WatchForceProtocol) {
        synchronizeAccountScope()
        guard allProtocols.contains(where: { $0.id == protocolValue.id }) else {
            selectedId = WatchForceProtocol.movementStarter.id
            persistSelection()
            return
        }
        selectedId = protocolValue.id
        persistSelection()
    }

    /// Rebinds the in-memory catalog before any view can render rows from the
    /// previous account. `AuthManager` stores the new relay before publishing
    /// its state, but this synchronous seam also protects direct navigation and
    /// offline/auth-failure transitions that happen without a view update.
    func synchronizeAccountScope() {
        let currentUserId = accountIdProvider()
        guard !didSynchronizeAccountScope || currentUserId != scopedUserId else { return }

        didSynchronizeAccountScope = true
        scopedUserId = currentUserId
        refreshGeneration &+= 1
        myProtocols = []
        fetchedAt = nil
        errorMessage = nil
        selectedId = WatchForceProtocol.movementStarter.id
        status = .loading
        restoreCache(for: currentUserId)
    }

    func refresh() async {
        // This must happen before setting loading or starting a request, so a
        // refresh begun during account transition cannot expose the old rows.
        synchronizeAccountScope()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        status = .loading
        errorMessage = nil

        // Capture the injected Sendable operation, rather than `self`, before
        // handing it to the timeout task group which may run off the actor.
        let fetch = fetchProtocols
        var fetched: [WatchForceProtocol]?
        var lastError: Error?
        var sawUnauthenticatedEmpty = false

        for attempt in 0..<Self.maxAttempts {
            guard isCurrent(generation) else { return }
            let authenticatedBeforeRequest = hasUsableRelayedSession
            do {
                fetched = try await withTimeout(
                    seconds: Self.perAttemptTimeoutSeconds,
                    operation: { try await fetch() }
                )
                // A non-empty response is unambiguous, so stop immediately.
                // Empty responses still get the remaining retries because they
                // are also what an unauthenticated RLS request can look like.
                if let fetched, !fetched.isEmpty { break }
                if fetched?.isEmpty == true && !authenticatedBeforeRequest {
                    sawUnauthenticatedEmpty = true
                }
            } catch is CancellationError {
                return
            } catch {
                lastError = error
            }

            guard isCurrent(generation) else { return }
            guard attempt + 1 < Self.maxAttempts else { break }
            do {
                try await Task.sleep(for: .milliseconds(Self.retryDelaysMs[attempt]))
            } catch {
                return
            }
        }

        guard isCurrent(generation) else { return }

        guard let fetched else {
            // `technicalDescription` is expected non-nil here — `fetched ==
            // nil` only happens after a non-cancellation `catch` set
            // `lastError` — but a defensive log line stays cheap insurance,
            // and `BackendFailureReason(error:)` gives the nil case an
            // explicit, correct meaning (#536 review finding 8) rather than
            // classifying an empty string as an unrecognized error.
            let technicalDescription = lastError?.localizedDescription
            if let technicalDescription {
                // `privacy: .public` is required: OSLog redacts dynamic
                // string interpolation by default, so without this a real
                // Watch's Console/log collect would show only "<private>",
                // failing AC #4 (#536 review finding 4). The error text
                // itself is never user data.
                Self.log.error("catalog refresh failed: \(technicalDescription, privacy: .public)")
            } else {
                Self.log.error("catalog refresh failed: no response from iPhone")
            }
            status = hasCachedSnapshot ? .cached : .failed
            errorMessage = ForceProtocolSyncCopy.message(for: BackendFailureReason(error: lastError))
            return
        }

        if fetched.isEmpty && (sawUnauthenticatedEmpty || !hasUsableRelayedSession) {
            // Never interpret an anonymous/RLS empty success as a real empty
            // catalog. This keeps both the rows and selected custom id intact.
            if hasCachedSnapshot {
                errorMessage = "Waiting for iPhone sign-in."
                status = .cached
            } else {
                errorMessage = "Waiting for your iPhone to finish signing in."
                status = .failed
            }
            return
        }

        // This is the only point where the server response is allowed to
        // replace the local catalog. The generation guard above makes a stale
        // task harmless even if a newer retry was started while this request
        // was in flight.
        myProtocols = fetched
        fetchedAt = Date()
        status = fetched.isEmpty ? .empty : .fresh
        persistCache()
        reconcileSelection()
    }

    private var hasUsableRelayedSession: Bool {
        guard let session = WatchSessionStore.shared.current else { return false }
        return !session.accessToken.isEmpty
            && session.expiresAt > Date().timeIntervalSince1970 + 5
    }

    private func isCurrent(_ generation: Int) -> Bool {
        guard !Task.isCancelled && generation == refreshGeneration else { return false }
        guard accountIdProvider() == scopedUserId else {
            synchronizeAccountScope()
            return false
        }
        return true
    }

    private func restoreCache(for userId: UUID?) {
        guard let userId else {
            status = .loading
            return
        }
        guard
            let data = defaults.data(forKey: Self.cacheKey(for: userId)),
            let cache = try? JSONDecoder().decode(Cache.self, from: data)
        else {
            status = .loading
            return
        }
        selectedId = defaults.string(forKey: Self.selectedKey(for: userId))
            ?? WatchForceProtocol.movementStarter.id
        myProtocols = cache.protocols
        fetchedAt = cache.fetchedAt
        status = .cached
        reconcileSelection()
    }

    private func persistCache() {
        guard let fetchedAt, let userId = scopedUserId else { return }
        let cache = Cache(protocols: myProtocols, fetchedAt: fetchedAt)
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: Self.cacheKey(for: userId))
        }
    }

    private func persistSelection() {
        guard let userId = scopedUserId else { return }
        defaults.set(selectedId, forKey: Self.selectedKey(for: userId))
    }

    private func reconcileSelection() {
        guard !allProtocols.contains(where: { $0.id == selectedId }) else { return }
        selectedId = WatchForceProtocol.movementStarter.id
        persistSelection()
    }

    private static func cacheKey(for userId: UUID) -> String {
        cacheKeyPrefix + userId.uuidString.lowercased()
    }

    private static func selectedKey(for userId: UUID) -> String {
        selectedKeyPrefix + userId.uuidString.lowercased()
    }
}
