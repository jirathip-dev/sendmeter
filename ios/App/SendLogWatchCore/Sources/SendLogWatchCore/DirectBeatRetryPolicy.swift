import Foundation

/// Retry policy for a failed direct WatchConnectivity workout beat (#614).
///
/// The workout mirror's WC send is fire-and-forget on a ~5s heartbeat cadence:
/// when a discrete transition (start/phase/count/end) is dropped because the
/// phone is momentarily unreachable, the phone otherwise waits up to ~5s for
/// the next heartbeat to show it. That is the confirmed latency defect this
/// policy bounds — one short, automatic re-send of a failed discrete
/// transition, capped so a sustained outage degrades back to the durable
/// Supabase heartbeat instead of hammering the link.
///
/// A pure decision so the cap arithmetic is Linux-testable; the transport
/// wiring lives in `WorkoutManager`.
public enum DirectBeatRetryPolicy {
    /// Delay before one automatic re-send of a failed discrete transition.
    public static let retryDelayS: TimeInterval = 0.5

    /// Upper bound on consecutive automatic retries while the phone stays
    /// unreachable. Beyond this the 5s heartbeat (and, for End, the durable
    /// `live_workouts` row) is the recovery — no unbounded retry loop.
    public static let maxConsecutiveRetries = 2

    /// Whether a failure of `event` should schedule another automatic send.
    ///
    /// - Telemetry is never retried: the next heartbeat (≤5s) carries the
    ///   same state at a higher sequence, so an extra send buys nothing.
    /// - `retryInFlight` dedupes to one pending re-send at a time.
    /// - `consecutiveFailures` bounds the burst; a success (the phone's ack)
    ///   resets it, so a healthy stretch never eats into the cap.
    public static func shouldRetry(
        event: LiveMirrorEvent,
        consecutiveFailures: Int,
        retryInFlight: Bool
    ) -> Bool {
        event.isDiscrete && !retryInFlight && consecutiveFailures < maxConsecutiveRetries
    }
}
