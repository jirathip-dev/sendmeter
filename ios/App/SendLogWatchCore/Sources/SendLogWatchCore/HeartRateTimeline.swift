import Foundation

/// One heart-rate reading, stamped with the SAMPLE time — the instant
/// HealthKit says the reading pertains to
/// (`HKStatistics.mostRecentQuantityDateInterval()`), not the time the
/// delegate callback happened to be invoked. `Date()` at the callback site
/// measures delivery, which lags — sometimes by a lot — behind the sensor
/// (#477).
public struct HeartRateSample: Equatable, Sendable {
    public let value: Double
    public let sampleAt: Date

    public init(value: Double, sampleAt: Date) {
        self.value = value
        self.sampleAt = sampleAt
    }
}

/// Tracks the most recently ACCEPTED heart-rate sample and answers "what
/// should the app treat as the current HR right now" — nil past a staleness
/// bound, never a silently-held old value (#477).
///
/// Two separate problems live here, and both are needed:
///
/// 1. **Ordering.** `HKLiveWorkoutBuilderDelegate.didCollectDataOf` can fire
///    more than once close together, and each firing's follow-up work can
///    itself be scheduled independently (a `Task` hop, a dispatch). Two
///    callbacks whose HealthKit-reported sample times are already in order
///    can still have their FOLLOW-UP work land out of order, moving the
///    observed HR backwards. Collapsing scheduling hops reduces how often
///    that happens but cannot prove it never does — `accept(_:)` rejects any
///    candidate whose `sampleAt` is not strictly newer than the one already
///    stored, so an out-of-order arrival is a no-op instead of a regression.
/// 2. **Staleness.** Delivery can stop entirely (bad contact, a sensor gap,
///    a session that never really got going) while the app keeps ticking at
///    1 Hz. `freshValue(at:maxAgeS:)` is the single place that decides
///    "current" vs. "absent" — every consumer (the detector's `MotionSample`,
///    the persisted `rawTrace`, the phone/Supabase heartbeat) must go through
///    it rather than reading a held value directly, or the staleness rule is
///    only half-applied.
public struct HeartRateTimeline: Sendable {
    private var latest: HeartRateSample?

    public init() {}

    /// The most recently accepted sample, regardless of age. Exposed for
    /// callers that need the raw state; most production code should go
    /// through `freshValue(at:maxAgeS:)` instead.
    public var current: HeartRateSample? { latest }

    /// Accepts `candidate` as the new latest reading iff its sample time is
    /// strictly newer than whatever is already stored. Returns whether it was
    /// accepted, so a caller can distinguish "updated" from "stale arrival
    /// discarded" if it wants to.
    @discardableResult
    public mutating func accept(_ candidate: HeartRateSample) -> Bool {
        if let latest, candidate.sampleAt <= latest.sampleAt {
            return false
        }
        latest = candidate
        return true
    }

    /// The HR value to treat as current at `now`: nil if nothing has ever
    /// been accepted, or if the freshest accepted sample is older than
    /// `maxAgeS`.
    public func freshValue(at now: Date, maxAgeS: TimeInterval) -> Double? {
        guard let latest, now.timeIntervalSince(latest.sampleAt) <= maxAgeS else { return nil }
        return latest.value
    }
}
