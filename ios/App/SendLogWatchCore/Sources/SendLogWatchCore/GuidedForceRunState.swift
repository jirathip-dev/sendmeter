import Foundation

/// Events emitted by the wall-clock guided force state machine.
///
/// The watch UI may receive a timer callback late (or not at all while the
/// app is suspended).  `GuidedForceRunState.advance` therefore emits every
/// boundary between the previous and current wall-clock samples, in order.
/// The app-side runner turns these events into the synchronous Tindeq manager
/// calls and owns the exactly-once persistence ledger.
public enum GuidedForceRunEvent: Sendable, Equatable {
    case prepare
    case startMovement(set: Int)
    case direction(WatchForceProtocol.TimelineSegment.Direction)
    case finishMovement(set: Int)
    case startStaticHold(set: Int, rep: Int)
    case finishStaticHold(set: Int, rep: Int)
    case rest(set: Int, rep: Int?)
    case completed
    case stopped
}

/// The values needed to render one glanceable runner frame.  The active
/// recording fields are state-machine fields rather than a second timer, so a
/// foreground refresh cannot disagree with persistence about the current set.
public struct GuidedForceRunSnapshot: Sendable, Equatable {
    public let elapsedS: Double
    public let remainingS: Double
    public let progress: Double
    public let segment: WatchForceProtocol.TimelineSegment?
    public let segmentRemainingS: Double
    public let activeKind: GuidedForceRecordingKind?
    public let activeSet: Int?
    public let activeRep: Int?
    public let isComplete: Bool
    public let isStopped: Bool

    public init(
        elapsedS: Double,
        remainingS: Double,
        progress: Double,
        segment: WatchForceProtocol.TimelineSegment?,
        segmentRemainingS: Double,
        activeKind: GuidedForceRecordingKind?,
        activeSet: Int?,
        activeRep: Int?,
        isComplete: Bool,
        isStopped: Bool
    ) {
        self.elapsedS = elapsedS
        self.remainingS = remainingS
        self.progress = progress
        self.segment = segment
        self.segmentRemainingS = segmentRemainingS
        self.activeKind = activeKind
        self.activeSet = activeSet
        self.activeRep = activeRep
        self.isComplete = isComplete
        self.isStopped = isStopped
    }
}

/// Foundation-only, wall-clock-derived execution state for a guided force
/// protocol.  It intentionally does not know about Bluetooth, SwiftUI, or
/// persistence.  That keeps delayed-tick and exactly-once boundary behavior
/// testable on the host and lets the watch runner stay a thin adapter.
public struct GuidedForceRunState: Sendable, Equatable {
    public let protocolValue: WatchForceProtocol
    public let runId: UUID
    public let startedAt: Date

    public private(set) var lastElapsedS: Double
    public private(set) var activeKind: GuidedForceRecordingKind?
    public private(set) var activeSet: Int?
    public private(set) var activeRep: Int?
    public private(set) var activeStartedS: Double?
    public private(set) var activeEndS: Double?
    public private(set) var isTerminal: Bool
    public private(set) var isStopped: Bool

    private let epsilon = 0.000_001

    public init(
        protocolValue: WatchForceProtocol,
        runId: UUID,
        startedAt: Date
    ) {
        self.protocolValue = protocolValue
        self.runId = runId
        self.startedAt = startedAt
        // Include the preparation boundary at t=0 on the first advance.
        self.lastElapsedS = -Double.leastNonzeroMagnitude
        self.activeKind = nil
        self.activeSet = nil
        self.activeRep = nil
        self.activeStartedS = nil
        self.activeEndS = nil
        self.isTerminal = false
        self.isStopped = false
    }

    /// Advances from the last observed wall-clock value to `now`.
    public mutating func advance(now: Date) -> [GuidedForceRunEvent] {
        advance(elapsedS: now.timeIntervalSince(startedAt))
    }

    /// Advances the state machine to an elapsed wall-clock value.  Every
    /// crossed segment boundary is processed once, even if the interval spans
    /// several concentric/eccentric phases or an inter-set rest.
    public mutating func advance(elapsedS: Double) -> [GuidedForceRunEvent] {
        guard !isTerminal else { return [] }

        let upper = boundedElapsed(elapsedS)
        var events: [GuidedForceRunEvent] = []

        var crossed = protocolValue.crossedSegments(from: lastElapsedS, to: upper)
        // `WatchForceProtocol.crossedSegments` intentionally clamps its lower
        // bound to zero.  Add the preparation boundary explicitly on the
        // first advance so the runner gets its initial cue as well.
        if lastElapsedS < 0,
           let prepare = protocolValue.timeline.first(where: { $0.startS == 0 }) {
            crossed.insert(prepare, at: 0)
        }

        for segment in crossed {
            if let activeEndS, activeEndS <= segment.startS + epsilon {
                finishActive(into: &events)
            }

            switch segment.phase {
            case .prepare:
                events.append(.prepare)
            case .hold:
                if activeKind == nil {
                    activeKind = .staticHold
                    activeSet = segment.set
                    activeRep = segment.rep
                    activeStartedS = segment.startS
                    activeEndS = segment.startS + segment.durationS
                    events.append(.startStaticHold(set: segment.set, rep: segment.rep))
                }
            case .concentric:
                // A movement set is one continuous recording across all of
                // its concentric/eccentric repetitions.
                if activeKind == nil {
                    activeKind = .movementSet
                    activeSet = segment.set
                    activeRep = nil
                    activeStartedS = segment.startS
                    activeEndS = movementSetEnd(set: segment.set)
                    events.append(.startMovement(set: segment.set))
                } else {
                    events.append(.direction(.concentric))
                }
            case .eccentric:
                events.append(.direction(.eccentric))
            case .rest, .setRest:
                events.append(.rest(set: segment.set, rep: segment.phase == .rest ? segment.rep : nil))
            }
        }

        lastElapsedS = max(lastElapsedS, upper)

        if upper >= protocolValue.durationS - epsilon {
            finishActive(into: &events)
            isTerminal = true
            events.append(.completed)
        }

        return events
    }

    /// Ends a run at the current wall-clock position.  If a set/hold is
    /// active it emits exactly one finish event so the persistence layer can
    /// save the honest partial duration; no completion event is emitted.
    public mutating func stop(now: Date) -> [GuidedForceRunEvent] {
        stop(elapsedS: now.timeIntervalSince(startedAt))
    }

    public mutating func stop(elapsedS: Double) -> [GuidedForceRunEvent] {
        guard !isTerminal else { return [] }

        var events = advance(elapsedS: elapsedS)
        guard !isTerminal else { return events }

        finishActive(into: &events)
        isStopped = true
        isTerminal = true
        events.append(.stopped)
        return events
    }

    public func snapshot(now: Date) -> GuidedForceRunSnapshot {
        snapshot(elapsedS: now.timeIntervalSince(startedAt))
    }

    public func snapshot(elapsedS: Double) -> GuidedForceRunSnapshot {
        let timelineSnapshot = protocolValue.snapshot(at: elapsedS)
        return GuidedForceRunSnapshot(
            elapsedS: timelineSnapshot.elapsedS,
            remainingS: timelineSnapshot.remainingS,
            progress: timelineSnapshot.progress,
            segment: timelineSnapshot.segment,
            segmentRemainingS: timelineSnapshot.segmentRemainingS,
            activeKind: activeKind,
            activeSet: activeSet,
            activeRep: activeRep,
            isComplete: isTerminal && !isStopped,
            isStopped: isStopped
        )
    }

    private func boundedElapsed(_ elapsedS: Double) -> Double {
        min(max(0, elapsedS), protocolValue.durationS)
    }

    private func movementSetEnd(set: Int) -> Double? {
        protocolValue.timeline
            .filter { $0.set == set && ($0.phase == .concentric || $0.phase == .eccentric) }
            .last
            .map { $0.startS + $0.durationS }
    }

    private mutating func finishActive(into events: inout [GuidedForceRunEvent]) {
        guard let activeKind, let activeSet else { return }

        switch activeKind {
        case .movementSet:
            events.append(.finishMovement(set: activeSet))
        case .staticHold:
            events.append(.finishStaticHold(set: activeSet, rep: activeRep ?? 1))
        }
        self.activeKind = nil
        self.activeSet = nil
        self.activeRep = nil
        self.activeStartedS = nil
        self.activeEndS = nil
    }
}
