import Foundation
import Supabase

enum SupabaseService {
    /// Session (incl. refresh token) persists in the Keychain automatically —
    /// KeychainLocalStorage is the SDK default on Apple platforms.
    ///
    /// `autoRefreshToken: false` — the watch is a *consumer* of the session
    /// the iPhone relays, and must never refresh it. Supabase refresh tokens
    /// are single-use; the phone's supabase-js owns the rotation, so a watch
    /// refresh attempt with the (already-rotated) shared token trips the
    /// "compromised refresh token" replay detection, which revokes the whole
    /// session family — the watch then falls back to anon and every write
    /// fails RLS. Fresh access tokens arrive via the phone relay instead
    /// (on every auth event + app foreground).
    static let client: SupabaseClient = {
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
            options: SupabaseClientOptions(auth: .init(autoRefreshToken: false))
        )
    }()
}
