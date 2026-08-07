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
/// Reads must be synchronous: the `accessToken` provider below runs on every
/// request, including on a background HealthKit wake.
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

/// The plugin owns its own Supabase client (separate from the WebView's
/// supabase-js session, which native code — especially a background wake —
/// can't reach). The access token is handed in via the auth relay
/// (`SendLogHealth.setSession`), mirroring the watch auth bridge. The URL and
/// publishable anon key are the same public values committed in
/// src/lib/supabase.ts and the watch's SupabaseConfig.plist — safe to embed;
/// RLS is the security boundary.
enum HealthConfig {
    // Simulator-only: localhost is meaningless on a physical device, so
    // Debug-on-device deliberately stays on the hosted project (test there
    // with a throwaway account) — only the simulator gets pointed at the
    // local Supabase stack.
    #if DEBUG && targetEnvironment(simulator)
    private static let supabaseURL = URL(string: "http://127.0.0.1:54321")!
    private static let supabaseAnonKey = "sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH"
    #else
    private static let supabaseURL = URL(string: "https://zznsqmcewtzlnfoiefkk.supabase.co")!
    private static let supabaseAnonKey = "sb_publishable_eHRHTelsNVGOcURw4q9a1Q_r6sas-rp"
    #endif

    /// ONE client, `private`, with no auth session of its own (#265, #502).
    /// It sends the relayed access token as a bearer token and nothing else;
    /// there is no `AuthClient` here to refresh, recover or rotate anything.
    ///
    /// This costs nothing in capability. Under #196 the data client already
    /// refused to refresh, so a background wake whose relayed token had
    /// expired already failed with a 401 and waited for the next foreground
    /// relay. The only behaviour removed is the refresh that
    /// `auth.setSession` could perform — the one nobody wanted.
    ///
    /// `private` is the #502 change: the rest of this plugin can no longer
    /// name the client, alias it, or reach any auth accessor through it —
    /// the compiler enforces what #196's convention and #488's text scans
    /// could not. Everything goes through `from(_:)` below, whose
    /// `PostgrestQueryBuilder` has no member path back to the client or to
    /// `.auth`. The residual trusted surface is THIS FILE, which
    /// `src/lib/nativeAuthInvariants.test.ts`'s (much smaller) pin scans.
    private static let client: SupabaseClient = {
        let authOptions = SupabaseClientOptions.AuthOptions(
            // Argument order is enforced by the initialiser.
            autoRefreshToken: false,
            accessToken: { HealthSessionStore.shared.accessToken }
        )
        // Names this process in Supabase's logs (#265 asked for origin
        // attribution): a request from the health plugin is now
        // distinguishable from one made by the WebView or the watch.
        let globalOptions = SupabaseClientOptions.GlobalOptions(
            headers: ["X-Client-Info": "sendmeter-health-plugin"]
        )
        return SupabaseClient(
            supabaseURL: supabaseURL,
            supabaseKey: supabaseAnonKey,
            options: SupabaseClientOptions(auth: authOptions, global: globalOptions)
        )
    }()

    /// The façade's entire data surface: a PostgREST query builder for one
    /// table. Deliberately the ONLY non-private member — anything new this
    /// plugin needs from the SDK gets its own narrow accessor here, never
    /// the client itself.
    static func from(_ table: String) -> PostgrestQueryBuilder {
        client.from(table)
    }
}
