import Foundation
import Supabase

/// The plugin's Keychain copy of the relayed **access token** (#265).
///
/// Same reasoning as the watch's `WatchSessionStore`: this plugin is a
/// consumer of the WebView's session, it has no business rotating anything,
/// and a bearer token it cannot renew is all it needs. It used to hold a
/// refresh token — `auth.setSession` was handed the pair, persisted both, and
/// (per supabase-swift) *refreshes on the spot* whenever the access token it
/// receives has already expired. `autoRefreshToken: false` does not prevent
/// that, which is what #196 discovered; #265 removes the credential instead of
/// forbidding the call.
///
/// Reads must be synchronous: `HealthConfig`'s `accessToken` provider runs on
/// every request, including on a background HealthKit wake.
///
/// Lives in its own file on purpose (#502): `HealthConfig.swift` holds the
/// `private` Supabase client, and Swift's `private` is file-scoped — any type
/// sharing that file could reach the client, so the façade file contains the
/// façade and nothing else, and the pin in
/// `src/lib/nativeAuthInvariants.test.ts` holds its whole surface to an
/// allow-list.
final class HealthSessionStore: @unchecked Sendable {
    static let shared = HealthSessionStore()

    private let storage = KeychainLocalStorage(service: "com.jirathip.sendlog.health.relay")
    private let key = "relayed-access-token"

    private let lock = NSLock()
    private var cached: String?
    private var loaded = false

    private init() {}

    var accessToken: String? {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            loaded = true
            // `retrieve` throws (rather than returning nil) when absent.
            let data = (try? storage.retrieve(key: key)) ?? nil
            cached = data.flatMap { String(data: $0, encoding: .utf8) }
        }
        return cached
    }

    func store(_ token: String) {
        lock.lock()
        cached = token
        loaded = true
        lock.unlock()
        try? storage.store(key: key, value: Data(token.utf8))
    }

    func clear() {
        lock.lock()
        cached = nil
        loaded = true
        lock.unlock()
        try? storage.remove(key: key)
    }

    /// Deletes whatever supabase-swift's `AuthClient` persisted under its
    /// default service on this device — the refresh token relayed to builds
    /// before #265. Run on every load, not once behind a flag: the guarantee
    /// is "no rotating credential lives here", and it must not depend on a
    /// boolean having been set correctly one time.
    func purgeLegacySupabaseKeychain() {
        let legacy = KeychainLocalStorage()
        for key in ["supabase.auth.token", "supabase.auth.token-code-verifier"] {
            try? legacy.remove(key: key)
        }
    }
}
