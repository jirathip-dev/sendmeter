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
/// Reads must be synchronous: a cold native launch restores the JWT subject
/// before any readiness request can publish, while each request captures its
/// bearer before leaving the session lock.
///
/// Lives in its own file on purpose (#502): the pin in
/// `src/lib/nativeAuthInvariants.test.ts` holds `HealthConfig.swift`'s whole
/// declaration surface to a two-line allow-list — the façade and nothing
/// else — and this class's members would all read as offenders there. The
/// move also shrinks the trusted file review must read. (Its old spot was
/// safe compiler-wise: `private` on a type member is not file-scoped, so
/// this class never could reach the client — the #502 reviews verified
/// that with compile probes.)
final class HealthSessionStore: @unchecked Sendable {
    static let shared = HealthSessionStore()

    private let storage = KeychainLocalStorage(service: "com.jirathip.sendlog.health.relay")
    private let key = "relayed-access-token"
    /// Shared with the auth bridge. This durable marker prevents a stale
    /// bearer surviving a process restart from resurrecting a signed-out
    /// readiness account before the next WebView relay arrives.
    private let signedOutKey = "sendmeter.authBridge.signedOut"

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
        UserDefaults.standard.set(false, forKey: signedOutKey)
    }

    func clear() {
        lock.lock()
        cached = nil
        loaded = true
        lock.unlock()
        try? storage.remove(key: key)
        UserDefaults.standard.set(true, forKey: signedOutKey)
    }

    var isSignedOut: Bool {
        UserDefaults.standard.bool(forKey: signedOutKey)
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
