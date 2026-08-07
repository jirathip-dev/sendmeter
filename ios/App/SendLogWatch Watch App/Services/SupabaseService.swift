import Foundation
import SendLogWatchCore
import Supabase

enum SupabaseService {
    /// ONE client, `private`, and it has no auth session of its own
    /// (issues #265, #502).
    ///
    /// The history here matters, because the previous attempts all looked
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
    /// - #265 removed the credential from the wire and the device, and a text
    ///   scan (`src/lib/nativeAuthInvariants.test.ts`) guarded the remaining
    ///   rule that no call site may reach a refreshing accessor. Three review
    ///   rounds (#488) each defeated that scan a different way.
    ///
    /// So the accessor is now unreachable *by construction* (#502): the
    /// client below is `private` to this file, and the only thing this façade
    /// exposes is `from(_:)` — a `PostgrestQueryBuilder`, which has no member
    /// path back to the client or to `.auth`. Code elsewhere in this target
    /// cannot name the client, alias it, or reach any auth accessor through
    /// it; the compiler enforces what #196's convention and #488's scans
    /// could not. The residual trusted surface is THIS FILE, which the
    /// (much smaller) text pin still scans — and NOTHING ELSE may live in
    /// this file, because Swift's `private` is file-scoped: a neighbouring
    /// type here could reach the client. The pin holds this file's whole
    /// declaration surface to an allow-list.
    ///
    /// The watch is handed a short-lived access token, keeps it in
    /// `WatchSessionStore`, and sends it as a bearer token. There is no
    /// `AuthClient` here to refresh anything, no Keychain session for the SDK
    /// to recover, and nothing a future call site could accidentally rotate.
    /// When the token expires the watch asks the phone for another
    /// (`AuthManager.requestSessionFromPhone`); only the phone's supabase-js
    /// owns rotation.
    private static let client: SupabaseClient = makeClient()

    /// The façade's entire data surface: a PostgREST query builder for one
    /// table. Every `Repo`/queue/live-sync call site goes through this.
    /// Deliberately the ONLY non-private member — anything new the watch
    /// needs from the SDK gets its own narrow accessor here, never the
    /// client itself.
    static func from(_ table: String) -> PostgrestQueryBuilder {
        client.from(table)
    }

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
