import Foundation

/// The account-owned result of a force-recording save.
///
/// A stale completion is not a persistence failure: its account no longer
/// owns the active model, so hands-free must leave its current controller
/// state and error surface alone.
public enum ForceSaveOutcome: Equatable, Sendable {
    case saved
    case failed
    case stale

    public var didPersist: Bool {
        self == .saved
    }

    public var shouldDisarmHandsFree: Bool {
        self == .failed
    }

    public var shouldReportHandsFreeFailure: Bool {
        self == .failed
    }
}
