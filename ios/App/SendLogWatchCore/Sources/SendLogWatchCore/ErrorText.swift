import Foundation

/// Maps raw backend/SDK errors to short, user-facing text for the watch UI —
/// so an auth/session hiccup reads as "signed out", not a database error.
/// Classification itself lives in `BackendFailureReason`, shared with
/// `ForceProtocolSyncCopy` — so a future save-failure call site gets the
/// same taxonomy for free. `friendly(_:)` has no call site of its own yet;
/// this file exists for whichever surface reaches for it next.
public enum ErrorText {
    public static func friendly(_ error: Error) -> String {
        switch BackendFailureReason(errorDescription: error.localizedDescription) {
        case .authExpired:
            return "Signed out — open the iPhone app to reconnect, then try again."
        case .unreachable:
            return "No connection — try again in a moment."
        case .unknown:
            return "Couldn't save. Try again."
        }
    }
}
