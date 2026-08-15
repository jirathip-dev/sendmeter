import Foundation

/// The HealthKit types whose background delivery wakes the app so readiness
/// can recompute while backgrounded (parity with the shipped plugin's
/// observer-driven ingestion, #629).
///
/// Raw identifier strings rather than HealthKit types keep this package free
/// of HealthKit so the seam is testable on macOS; `HealthKitService` maps
/// them to `HKObjectType`s. Background-delivery enablement and observer
/// registration both iterate this exact list, so delivery and observation
/// cannot drift apart — a type delivered to but not observed (or vice versa)
/// would silently never recompute.
public enum HealthObserverTypes {
    /// Exactly the four types the shipped plugin delivers: HRV SDNN, resting
    /// heart rate, respiratory rate, and sleep analysis.
    public static let observedIdentifiers: [String] = [
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
        "HKQuantityTypeIdentifierRestingHeartRate",
        "HKQuantityTypeIdentifierRespiratoryRate",
        "HKCategoryTypeIdentifierSleepAnalysis",
    ]
}

/// Single-flight gate for readiness recomputes, shared by the foreground sync
/// path and background HealthKit observer fires so a background fire during a
/// foreground sync cannot double-compute (mirrors the shipped plugin's
/// `ReadinessRefreshCoalescer`: at most one follow-up pass per owner flight,
/// no second timer).
///
/// The owner sets `request() == .start` before its first `await`; fires that
/// arrive during the pass coalesce into at most one follow-up, executed by
/// the same owner when `complete()` reports `.rerun` — never by a second
/// concurrent caller. `cancel()` aborts a pass and drops any queued follow-up.
public struct ReadinessRecomputeGate: Equatable, Sendable {
    public enum Request: Equatable, Sendable {
        case start
        case queued
    }

    public enum Completion: Equatable, Sendable {
        case idle
        case rerun
    }

    private var running = false
    private var queued = false
    private var followUpConsumed = false

    public init() {}

    public var isRunning: Bool { running }

    public mutating func request() -> Request {
        guard running else {
            running = true
            followUpConsumed = false
            return .start
        }
        queued = true
        return .queued
    }

    public mutating func complete() -> Completion {
        precondition(running, "cannot complete an idle readiness recompute")
        guard queued, !followUpConsumed else {
            running = false
            queued = false
            return .idle
        }
        queued = false
        // Keep the single-flight owner running while it executes the already
        // authorized follow-up. A fire during the follow-up cannot queue a
        // third pass; it is dropped with the next completion.
        followUpConsumed = true
        return .rerun
    }

    /// Abort a failed pass. A late fire cannot resurrect the dropped
    /// follow-up, so the next fire starts a fresh pass.
    public mutating func cancel() {
        running = false
        queued = false
        followUpConsumed = false
    }
}
