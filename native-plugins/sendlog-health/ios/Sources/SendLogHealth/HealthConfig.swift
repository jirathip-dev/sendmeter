import Foundation
import PostgREST

/// The plugin owns a narrow PostgREST client (separate from the WebView's
/// supabase-js session, which native code — especially a background wake —
/// can't reach). The access token is handed in via the auth relay
/// (`SendLogHealth.setSession`), mirroring the watch auth bridge. The URL and
/// publishable anon key are the same public values committed in
/// src/lib/supabase.ts and the watch's SupabaseConfig.plist — safe to embed;
/// RLS is the security boundary.
///
/// NOTHING ELSE may live in this file (#502): the pin in
/// `src/lib/nativeAuthInvariants.test.ts` holds this file's whole
/// declaration surface to a two-line allow-list, which only works because
/// the façade is all there is — `HealthSessionStore` moved to its own file
/// so its members wouldn't read as offenders there. (`private` on a type
/// member is NOT file-scoped — a neighbouring type here could not reach
/// the client; compiler-verified in the #502 reviews. What does share it
/// is an `extension HealthConfig` in this file, and any non-private
/// `extension` line is flagged.)
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

    /// Every request gets a fresh private PostgREST client bound to the access
    /// token captured by its owning readiness flight (#520). The pinned
    /// supabase-swift SDK exposes this constructor directly in its PostgREST
    /// product, so this path does not create the full SDK client/auth surface.
    /// There is no auth session of its own and no live Keychain-backed provider
    /// here: an old request can therefore never start using a new account's
    /// bearer after a session transition.
    ///
    /// A client is cheap compared with a HealthKit read and keeps the bearer
    /// binding explicit at every PostgREST call site. The only native auth
    /// capability remains access-token transport; no refresh token is stored
    /// or handed to the SDK.
    ///
    /// `private` is the #502 change: the rest of this plugin can no longer
    /// name or mutate the client. Everything goes through `from(_:)` below,
    /// whose `PostgrestQueryBuilder` has no member path back to the client.
    /// The residual trusted surface is THIS FILE, which
    /// `src/lib/nativeAuthInvariants.test.ts`'s (much smaller) pin scans.
    private static func client(accessToken: String) -> PostgrestClient {
        PostgrestClient(
            url: supabaseURL.appendingPathComponent("rest/v1"),
            headers: [
                "apikey": supabaseAnonKey,
                "Authorization": "Bearer \(accessToken)",
                "X-Client-Info": "sendmeter-health-plugin"
            ]
        )
    }

    /// The façade's entire data surface: a PostgREST query builder for one
    /// table and one captured bearer. Deliberately the ONLY non-private member
    /// — anything new this plugin needs from the SDK gets its own narrow
    /// accessor here, never the client itself.
    static func from(_ table: String, accessToken: String) -> PostgrestQueryBuilder {
        client(accessToken: accessToken).from(table)
    }
}
