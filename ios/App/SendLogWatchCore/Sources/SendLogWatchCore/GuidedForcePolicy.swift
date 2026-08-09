import Foundation

/// Decisions that keep watch execution honest when a guided Progressor run
/// changes state.  The watch can continue movement cadence after a disconnect,
/// but a static hold cannot be resumed or alternated without the sensor.
public enum GuidedForceDisconnectPolicy {
    /// A salvaged movement set is one row in a run that may continue with
    /// cadence-only sets.  A salvaged static hold terminates its run so the
    /// manager can flush the recovered hold and log the terminal session.
    public static func shouldFinishSessionAfterSalvage(
        kind: GuidedForceRecordingKind?
    ) -> Bool {
        guard let kind else {
            // A missing claim is a safety/fallback path: do not leave an
            // already-open ordinary session hanging indefinitely.
            return true
        }
        return kind == .staticHold
    }
}

public enum GuidedForceStartEligibility: Equatable, Sendable {
    case allowed
    case requiresProgressor
    case alternatingSidesUnsupported
}

/// Returns whether a protocol can honestly be started on watch.  `alternate_sides`
/// is a static-only iPhone behavior; movement protocols remain runnable without
/// a sensor as cadence-only, while every static protocol requires one.
public func guidedForceStartEligibility(
    for protocolValue: WatchForceProtocol,
    sensorConnected: Bool
) -> GuidedForceStartEligibility {
    if protocolValue.mode == .hold, protocolValue.alternateSides {
        return .alternatingSidesUnsupported
    }
    if protocolValue.mode == .hold, !sensorConnected {
        return .requiresProgressor
    }
    return .allowed
}
