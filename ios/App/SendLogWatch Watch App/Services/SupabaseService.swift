import Foundation
import SendLogWatchCore
import Supabase

enum SupabaseService {
    /// ONE client, and it has no auth session of its own (issue #265).
    ///
    /// The history here matters, because the previous two attempts both looked
    /// right on inspection:
    ///
    /// - Originally the watch called `setSession(accessToken:refreshToken:)`
    ///   with the pair the phone relayed. supabase-swift persisted both to the
    ///   Keychain and refreshed on demand, so the watch would eventually
    ///   present a refresh token the phone had long since rotated — Supabase's
    ///   reuse detection then revoked the entire session family, signing the
    ///   phone out too.
    /// - #196 split the client in two and forbade every refreshing accessor by
    ///   convention. The convention held everywhere it was applied, and a
    ///   twelve-hour-stale token was still replayed in production on
    ///   2026-07-26 (#265).
    ///
    /// So the refresh token is gone from the wire and from the device. The
    /// watch is handed a short-lived access token, keeps it in
    /// `WatchSessionStore`, and sends it as a bearer token. There is no
    /// `AuthClient` here to refresh anything, no Keychain session for the SDK
    /// to recover, and nothing a future call site could accidentally rotate.
    /// When the token expires the watch asks the phone for another
    /// (`AuthManager.requestSessionFromPhone`); only the phone's supabase-js
    /// owns rotation.
    ///
    /// `data` keeps its name — every existing `Repo`/queue/live-sync call site
    /// already goes through it.
    static let data: SupabaseClient = makeClient()

    private static func makeClient() -> SupabaseClient {
        // No `AuthClient` involvement at all: `accessToken` makes the client
        // ask us for a bearer token per request. `autoRefreshToken` must
        // precede `accessToken` (initialiser argument order).
        let authOptions = SupabaseClientOptions.AuthOptions(
            autoRefreshToken: false,
            accessToken: { WatchSessionStore.shared.accessToken }
        )
        // Names this process in Supabase's logs (#265 asked for origin
        // attribution). The watch can no longer reach /token at all, so an
        // auth-log entry is by definition not from here — but every PostgREST
        // request it does make is now labelled.
        let globalOptions = SupabaseClientOptions.GlobalOptions(
            headers: ["X-Client-Info": "sendmeter-watch/\(WatchBuild.identity?.display ?? "?")"]
        )
        // Simulator-only: localhost is meaningless on a physical device, so
        // Debug-on-device deliberately stays on the hosted project (test
        // there with a throwaway account) — only the simulator gets pointed
        // at the local Supabase stack.
        #if DEBUG && targetEnvironment(simulator)
        return SupabaseClient(
            supabaseURL: URL(string: "http://127.0.0.1:54321")!,
            supabaseKey: "sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH",
            options: SupabaseClientOptions(auth: authOptions, global: globalOptions)
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
            options: SupabaseClientOptions(auth: authOptions, global: globalOptions)
        )
        #endif
    }
}
