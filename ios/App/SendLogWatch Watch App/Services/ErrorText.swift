import Foundation

/// Maps raw backend/SDK errors to short, user-facing text for the watch UI —
/// so an auth/session hiccup reads as "signed out", not a database error.
enum ErrorText {
    static func friendly(_ error: Error) -> String {
        let m = error.localizedDescription.lowercased()
        if m.contains("row-level security") || m.contains("jwt")
            || m.contains("not authenticated") || m.contains("unauthorized")
            || m.contains("permission") {
            return "Signed out — open the iPhone app to reconnect, then try again."
        }
        if m.contains("offline") || m.contains("network")
            || m.contains("connection") || m.contains("timed out")
            || m.contains("timeout") {
            return "No connection — try again in a moment."
        }
        return "Couldn't save. Try again."
    }
}
