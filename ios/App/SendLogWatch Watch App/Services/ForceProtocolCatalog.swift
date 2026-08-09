import Foundation
import Observation
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

    private static let cacheKey = "forceProtocolCatalog.v1"
    private static let selectedKey = "lastForceProtocolId"
    private static let maxAttempts = 3
    private static let perAttemptTimeoutSeconds: Double = 6
    private static let retryDelaysMs: [UInt64] = [250, 750]

    private let defaults: UserDefaults
    private(set) var myProtocols: [WatchForceProtocol] = []
    private(set) var fetchedAt: Date?
    private(set) var status: Status = .loading
    private(set) var errorMessage: String?
    private(set) var selectedId: String
    private var refreshGeneration = 0

    var suggested: [WatchForceProtocol] { [.movementStarter] }

    var selected: WatchForceProtocol {
        allProtocols.first { $0.id == selectedId } ?? .movementStarter
    }

    var allProtocols: [WatchForceProtocol] { suggested + myProtocols }

    var hasCachedSnapshot: Bool { fetchedAt != nil }

    var statusText: String? {
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedId = defaults.string(forKey: Self.selectedKey)
            ?? WatchForceProtocol.movementStarter.id
        restoreCache()
    }

    func select(_ protocolValue: WatchForceProtocol) {
        selectedId = protocolValue.id
        defaults.set(selectedId, forKey: Self.selectedKey)
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        status = .loading
        errorMessage = nil

        var fetched: [WatchForceProtocol]?
        var lastError: Error?
        var sawUnauthenticatedEmpty = false

        for attempt in 0..<Self.maxAttempts {
            guard isCurrent(generation) else { return }
            let authenticatedBeforeRequest = hasUsableRelayedSession
            do {
                fetched = try await withTimeout(
                    seconds: Self.perAttemptTimeoutSeconds,
                    operation: { try await Repo.fetchTindeqPresets() }
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
            errorMessage = lastError?.localizedDescription ?? "No response from your iPhone."
            status = hasCachedSnapshot ? .cached : .failed
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
        !Task.isCancelled && generation == refreshGeneration
    }

    private func restoreCache() {
        guard
            let data = defaults.data(forKey: Self.cacheKey),
            let cache = try? JSONDecoder().decode(Cache.self, from: data)
        else {
            status = .loading
            return
        }
        myProtocols = cache.protocols
        fetchedAt = cache.fetchedAt
        status = .cached
        reconcileSelection()
    }

    private func persistCache() {
        guard let fetchedAt else { return }
        let cache = Cache(protocols: myProtocols, fetchedAt: fetchedAt)
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: Self.cacheKey)
        }
    }

    private func reconcileSelection() {
        guard !allProtocols.contains(where: { $0.id == selectedId }) else { return }
        selectedId = WatchForceProtocol.movementStarter.id
        defaults.set(selectedId, forKey: Self.selectedKey)
    }
}
