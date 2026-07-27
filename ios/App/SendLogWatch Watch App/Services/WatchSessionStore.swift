import Foundation
import OSLog
import SendLogWatchCore
import Supabase

/// The watch's entire notion of "who is signed in": one relayed access token,
/// kept in the Keychain (issue #265).
///
/// It deliberately does NOT go through supabase-swift's `AuthClient`. That
/// client's session type requires a refresh token, `setSession` refreshes
/// whenever the access token it is handed has expired, and the resulting
/// Keychain copy of a rotating credential is exactly what replayed a
/// twelve-hour-old token in production and revoked a healthy session family.
/// The watch cannot refresh anything and must not look like it could: it holds
/// a bearer token with an expiry and nothing else. When that token dies the
/// only recovery is to ask the phone for another (`AuthManager`).
///
/// Reads are synchronous by contract — `OfflineQueue`/`PendingSessionQueue`
/// stamp and compare the signed-in user id on non-async paths, and the data
/// client's `accessToken` provider runs on every request. Hence `nonisolated`:
/// the target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which
/// would otherwise make every read an actor hop those call sites cannot take.
/// The `NSLock` is what actually makes concurrent access safe.
nonisolated final class WatchSessionStore: @unchecked Sendable {
    static let shared = WatchSessionStore()

    private static let log = Logger(subsystem: "com.jirathip.sendlog.watchkitapp", category: "auth")

    /// Namespaced away from supabase-swift's own Keychain service, so the
    /// legacy purge below can delete everything the SDK ever wrote without
    /// touching what we store.
    private let storage = KeychainLocalStorage(service: "com.jirathip.sendlog.watch.relay")
    private let key = "relayed-session"

    private let lock = NSLock()
    private var cached: RelayedSession?
    private var loaded = false

    private init() {}

    var current: RelayedSession? {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            loaded = true
            // `retrieve` throws (rather than returning nil) when the item is
            // absent, so flatten both layers of optionality.
            let data = (try? storage.retrieve(key: key)) ?? nil
            cached = data.flatMap { try? JSONDecoder().decode(RelayedSession.self, from: $0) }
        }
        return cached
    }

    /// Handed to the data client's `accessToken` provider. Returned regardless
    /// of expiry: an expired bearer token gets a 401, which is the correct and
    /// completely harmless outcome — unlike a refresh, it cannot rotate or
    /// revoke anything. Withholding it would only turn recoverable 401s into
    /// silent anon requests that fail RLS in a more confusing way.
    var accessToken: String? { current?.accessToken }

    var userId: UUID? { current?.userId }

    func store(_ session: RelayedSession) {
        lock.lock()
        cached = session
        loaded = true
        lock.unlock()
        if let data = try? JSONEncoder().encode(session) {
            try? storage.store(key: key, value: data)
        }
    }

    func clear() {
        lock.lock()
        cached = nil
        loaded = true
        lock.unlock()
        try? storage.remove(key: key)
    }

    /// Deletes anything supabase-swift's `AuthClient` persisted on this device
    /// under its default service — i.e. the refresh token relayed to builds
    /// before #265.
    ///
    /// Run on EVERY launch, not once behind a flag: the point is that no
    /// refresh token can survive on the wrist, and a one-shot migration would
    /// leave that guarantee resting on a boolean. It is a single
    /// `SecItemDelete` against a service nothing in this app writes to any
    /// more, so repeating it costs nothing and cannot delete live state.
    func purgeLegacySupabaseKeychain() {
        let legacy = KeychainLocalStorage()
        for key in ["supabase.auth.token", "supabase.auth.token-code-verifier"] {
            try? legacy.remove(key: key)
        }
        Self.log.debug("purged legacy supabase-swift keychain items")
    }
}
