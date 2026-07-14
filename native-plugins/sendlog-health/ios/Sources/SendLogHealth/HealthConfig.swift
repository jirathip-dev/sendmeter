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
    static let supabaseURL = URL(string: "https://zznsqmcewtzlnfoiefkk.supabase.co")!
    static let supabaseAnonKey = "sb_publishable_eHRHTelsNVGOcURw4q9a1Q_r6sas-rp"

    /// Session (incl. refresh token) persists in the Keychain automatically —
    /// KeychainLocalStorage is the SDK default on Apple platforms, so a
    /// background wake reuses the last relayed session without a round-trip.
    static let client = SupabaseClient(
        supabaseURL: supabaseURL,
        supabaseKey: supabaseAnonKey
    )
}
