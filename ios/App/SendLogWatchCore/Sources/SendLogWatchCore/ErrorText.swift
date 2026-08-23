import Foundation

/// Maps raw backend/SDK errors to short, user-facing text for the watch UI —
/// so an auth/session hiccup reads as "signed out", not a database error.
/// Classification itself lives in `BackendFailureReason`, shared with
/// `ForceProtocolSyncCopy`; each context below supplies its own fixed copy so
/// a generic fallback can never claim a save or a connection happened.
/// Raw diagnostics stay in logs and the gated quarantine surface.
public enum ErrorText {
    public enum Class: Sendable, Equatable {
        case authExpired
        case unreachable
        case saveFailed
        case workoutStartFailed
        case workoutFailed
        case workoutHealthSaveFailed
        case readinessUnavailable
        case progressorUnavailable
        case progressorUnsupported
        case progressorNotFound
        case progressorConnectFailed
        case progressorDisconnected
        case progressorUnrecognized
        case forceSessionSaveFailed
        case repNotSaved
        case repNotSavedOnWatch
        case recordingNotSavedOnWatch
    }

    public static func message(for classification: Class) -> String {
        switch classification {
        case .authExpired:
            return "Signed out — open the iPhone app to reconnect, then try again."
        case .unreachable:
            return "No connection — try again in a moment."
        case .saveFailed:
            return "Couldn't save. Try again."
        case .workoutStartFailed:
            return "Couldn't start the workout. Check Health access on your iPhone, then try again."
        case .workoutFailed:
            return "The workout stopped unexpectedly. Check Health access on your iPhone, then try again."
        case .workoutHealthSaveFailed:
            return "Apple Health couldn't save this workout. Check Health access on your iPhone, then try again."
        case .readinessUnavailable:
            return "Couldn't reach your iPhone. Try again when it's nearby."
        case .progressorUnavailable:
            return "Bluetooth is unavailable. Turn it on and try connecting again."
        case .progressorUnsupported:
            return "This watch can't connect to a Progressor over Bluetooth."
        case .progressorNotFound:
            return "Couldn't find the Progressor. Make sure it's on and nearby, then try again."
        case .progressorConnectFailed:
            return "Couldn't connect to the Progressor. Make sure it's on and nearby, then try again."
        case .progressorDisconnected:
            return "The Progressor disconnected. Reconnect it and try again."
        case .progressorUnrecognized:
            return "The Progressor wasn't recognised. Turn it off and on, then try connecting again."
        case .forceSessionSaveFailed:
            return "Force session wasn't saved. Your pulls may still be saved individually; create a session for them on your phone."
        case .repNotSaved:
            return "Rep wasn't saved. Try pulling again."
        case .repNotSavedOnWatch:
            return "Rep couldn't be saved on the watch. It won't appear in this workout."
        case .recordingNotSavedOnWatch:
            return "Recording couldn't be saved on the watch. It won't appear in this workout."
        }
    }

    /// Whether a saved-message string means a recording could not be kept.
    /// Fixed copy in, fixed verdict out, so UI styling never drifts from the
    /// wording (#758).
    public static func isFailureMessage(_ message: String) -> Bool {
        message == Self.message(for: .repNotSaved)
            || message == Self.message(for: .repNotSavedOnWatch)
            || message == Self.message(for: .recordingNotSavedOnWatch)
            || message == "Rep not saved — try pulling again"
    }

    public static func friendly(_ error: Error) -> String {
        switch BackendFailureReason(errorDescription: error.localizedDescription) {
        case .authExpired:
            return message(for: .authExpired)
        case .unreachable:
            return message(for: .unreachable)
        case .unknown:
            return message(for: .saveFailed)
        }
    }
}
