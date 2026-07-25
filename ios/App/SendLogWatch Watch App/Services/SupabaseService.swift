import Foundation
import Supabase

enum SupabaseService {
    /// Session (incl. refresh token) persists in the Keychain automatically —
    /// KeychainLocalStorage is the SDK default on Apple platforms.
    ///
    /// Two clients, not one (issue #196): `autoRefreshToken: false` alone
    /// does NOT stop a refresh — supabase-swift's default `.auth` accessor
    /// still refreshes an expired token on demand (inside `auth.session`),
    /// and the watch must never do that. It's a *consumer* of the session
    /// the iPhone relays; Supabase refresh tokens are single-use, and the
    /// phone's supabase-js owns the rotation, so a watch refresh attempt
    /// with the (already-rotated) shared token trips the "compromised
    /// refresh token" replay detection, which revokes the whole session
    /// family — the watch then falls back to anon and every write fails
    /// RLS. Fresh access tokens arrive via the phone relay instead (on
    /// every auth event + app foreground).
    ///
    /// - `auth`: the only client allowed to read `.auth` — `AuthManager`
    ///   uses it for `setSession`/`signIn`/`signOut`/`currentSession`. None
    ///   of those trigger a refresh.
    /// - `data`: every table/RPC call goes through this one instead. Its
    ///   `accessToken` provider hands back `auth`'s current Keychain token
    ///   WITHOUT refreshing it, so this client never needs `.auth` at all —
    ///   reading `.auth` on it would trip supabase-swift's own "use a
    ///   separate client" warning.
    static let auth: SupabaseClient = makeClient(accessToken: nil)

    static let data: SupabaseClient = makeClient(accessToken: {
        try? await SupabaseService.auth.auth.currentSession?.accessToken
    })

    private static func makeClient(
        accessToken: (@Sendable () async throws -> String?)?
    ) -> SupabaseClient {
        let authOptions = SupabaseClientOptions.AuthOptions(
            accessToken: accessToken,
            autoRefreshToken: false
        )
        // Simulator-only: localhost is meaningless on a physical device, so
        // Debug-on-device deliberately stays on the hosted project (test
        // there with a throwaway account) — only the simulator gets pointed
        // at the local Supabase stack.
        #if DEBUG && targetEnvironment(simulator)
        return SupabaseClient(
            supabaseURL: URL(string: "http://127.0.0.1:54321")!,
            supabaseKey: "sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH",
            options: SupabaseClientOptions(auth: authOptions)
        )
        #else
        guard
            let url = Bundle.main.url(forResource: "SupabaseConfig", withExtension: "plist"),
            let dict = NSDictionary(contentsOf: url) as? [String: String],
            let supabaseURL = dict["SUPABASE_URL"].flatMap(URL.init(string:)),
            let anonKey = dict["SUPABASE_ANON_KEY"]
        else {
            fatalError("SupabaseConfig.plist missing or malformed")
        }
        return SupabaseClient(
            supabaseURL: supabaseURL,
            supabaseKey: anonKey,
            options: SupabaseClientOptions(auth: authOptions)
        )
        #endif
    }
}
