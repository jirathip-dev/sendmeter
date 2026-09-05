import Foundation

/// The actions that may claim the Progressor stream from the phone Force tab.
/// A selected protocol is only a prescription; it is not a stream owner until
/// the run starts. Keeping that distinction in Core prevents a picker state
/// from being treated as a concurrency lock. #899: `.freePull` (the
/// direct-measure manual start) is removed — the remaining claimants are the
/// hands-free arm and a guided-protocol launch.
public enum ForceRecordingAction: String, Equatable, Sendable {
    case handsFree
    case guidedProtocol
}

/// The synchronous state needed before a Force action can claim the stream.
/// `protocolArmed` is intentionally informational: selecting a protocol must
/// coexist with the hands-free preference and must not be mistaken for an
/// active recording.
public struct ForceRecordingContextState: Equatable, Sendable {
    public let liveRecording: Bool
    public let handsFreeArmed: Bool
    public let protocolArmed: Bool

    public init(
        liveRecording: Bool,
        handsFreeArmed: Bool,
        protocolArmed: Bool
    ) {
        self.liveRecording = liveRecording
        self.handsFreeArmed = handsFreeArmed
        self.protocolArmed = protocolArmed
    }
}

public enum ForceRecordingStartDecision: Equatable, Sendable {
    /// The stream is free to be claimed immediately.
    case allowed
    /// A non-recording hands-free arm owns the transport, but can be handed
    /// back synchronously before a new owner starts.
    case safeHandoffFromArmedStream
    /// A live recording already owns the samples. It must be stopped and
    /// settled before another action can start.
    case refusedActiveRecording

    public var isAllowed: Bool {
        self == .allowed || self == .safeHandoffFromArmedStream
    }
}

/// Shared ownership policy for free pulls, hands-free, and guided protocols.
/// The first branch is deliberately the only refusal branch. A selected
/// protocol does not block a free action, and an armed-but-not-recording
/// hands-free stream has an explicit safe handoff rather than being conflated
/// with an active pull.
public enum ForceRecordingContextPolicy {
    public static func decision(
        for _: ForceRecordingAction,
        state: ForceRecordingContextState
    ) -> ForceRecordingStartDecision {
        if state.liveRecording {
            return .refusedActiveRecording
        }
        if state.handsFreeArmed {
            return .safeHandoffFromArmedStream
        }
        return .allowed
    }
}

/// The compact Force metadata controls have to remain immutable for the whole
/// window in which a recording owner can still persist samples.  In
/// particular, an armed hands-free stream is already the owner of the next
/// rep's attribution even though it is not measuring yet.
public struct ForceContextLockState: Equatable, Sendable {
    public let liveRecording: Bool
    public let interruptedRecording: Bool
    public let handsFreeArmed: Bool
    public let handsFreeMeasuring: Bool
    public let guidedSessionActive: Bool

    public init(
        liveRecording: Bool,
        interruptedRecording: Bool,
        handsFreeArmed: Bool,
        handsFreeMeasuring: Bool,
        guidedSessionActive: Bool
    ) {
        self.liveRecording = liveRecording
        self.interruptedRecording = interruptedRecording
        self.handsFreeArmed = handsFreeArmed
        self.handsFreeMeasuring = handsFreeMeasuring
        self.guidedSessionActive = guidedSessionActive
    }
}

public enum ForceContextLockPolicy {
    public static func isLocked(_ state: ForceContextLockState) -> Bool {
        state.liveRecording
            || state.interruptedRecording
            || state.handsFreeArmed
            || state.handsFreeMeasuring
            || state.guidedSessionActive
    }
}
