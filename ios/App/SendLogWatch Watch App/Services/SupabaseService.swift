import Foundation
import Supabase

enum SupabaseService {
    /// Session (incl. refresh token) persists in the Keychain automatically —
    /// KeychainLocalStorage is the SDK default on Apple platforms.
    static let client: SupabaseClient = {
        guard
            let url = Bundle.main.url(forResource: "SupabaseConfig", withExtension: "plist"),
            let dict = NSDictionary(contentsOf: url) as? [String: String],
            let supabaseURL = dict["SUPABASE_URL"].flatMap(URL.init(string:)),
            let anonKey = dict["SUPABASE_ANON_KEY"]
        else {
            fatalError("SupabaseConfig.plist missing or malformed")
        }
        return SupabaseClient(supabaseURL: supabaseURL, supabaseKey: anonKey)
    }()
}
