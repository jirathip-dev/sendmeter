import Foundation
import Supabase

/// The plugin owns its own Supabase client (separate from the WebView's
/// supabase-js session, which native code — especially a background wake —
/// can't reach). The session is handed in via the auth relay
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
    static let supabaseURL = URL(string: "http://127.0.0.1:54321")!
    static let supabaseAnonKey = "sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH"
    #else
    static let supabaseURL = URL(string: "https://zznsqmcewtzlnfoiefkk.supabase.co")!
    static let supabaseAnonKey = "sb_publishable_eHRHTelsNVGOcURw4q9a1Q_r6sas-rp"
    #endif

    /// Session (incl. refresh token) persists in the Keychain automatically —
    /// KeychainLocalStorage is the SDK default on Apple platforms, so a
    /// background wake reuses the last relayed session without a round-trip.
    ///
    /// Two clients, not one (issue #196): `autoRefreshToken: false` alone
    /// does NOT stop a refresh — supabase-swift's default `.auth` accessor
    /// still refreshes an expired token on demand (inside `auth.session`),
    /// and this plugin must never do that. It consumes the session relayed
    /// from the WebView's supabase-js, which owns the refresh cycle. Refresh
    /// tokens are single-use: if this client refreshed the shared token too,
    /// whichever refreshed second would trip replay detection and revoke the
    /// whole session family (breaking watch + web at once) — a background
    /// HealthKit wake is exactly the case where the relayed token is likely
    /// already expired. Fresh tokens arrive via relayHealthSession on every
    /// auth event + app foreground.
    ///
    /// - `auth`: the only client allowed to read `.auth` — `HealthSyncManager`
    ///   uses it for `setSession`/`signOut`. Neither triggers a refresh.
    /// - `data`: every table call goes through this one instead. Its
    ///   `accessToken` provider hands back `auth`'s current Keychain token
    ///   WITHOUT refreshing it, so this client never needs `.auth` at all —
    ///   reading `.auth` on it would trip supabase-swift's own "use a
    ///   separate client" warning.
    static let auth = SupabaseClient(
        supabaseURL: supabaseURL,
        supabaseKey: supabaseAnonKey,
        options: SupabaseClientOptions(auth: .init(autoRefreshToken: false))
    )

    static let data = SupabaseClient(
        supabaseURL: supabaseURL,
        supabaseKey: supabaseAnonKey,
        // autoRefreshToken must precede accessToken (initialiser order).
        options: SupabaseClientOptions(auth: .init(
            autoRefreshToken: false,
            accessToken: { try? await HealthConfig.auth.auth.currentSession?.accessToken }
        ))
    )
}
