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
            return errorMessage ?? "Offline · showing saved protocols"
        case .failed:
            return errorMessage ?? "Couldn’t sync protocols"
        }
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
            let technicalDescription = lastError?.localizedDescription
            if let technicalDescription {
                Self.log.error("catalog refresh failed: \(technicalDescription)")
            } else {
                Self.log.error("catalog refresh failed: no response from iPhone")
            }
            status = hasCachedSnapshot ? .cached : .failed
            errorMessage = ForceProtocolSyncCopy.message(
                for: BackendFailureReason(errorDescription: technicalDescription ?? ""),
                hasCachedSnapshot: hasCachedSnapshot
            )
            return
        }

        if fetched.isEmpty && (sawUnauthenticatedEmpty || !hasUsableRelayedSession) {
            // Never interpret an anonymous/RLS empty success as a real empty
            // catalog. This keeps both the rows and selected custom id intact.
            if hasCachedSnapshot {
                errorMessage = "Waiting for iPhone sign-in · showing saved protocols"
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
