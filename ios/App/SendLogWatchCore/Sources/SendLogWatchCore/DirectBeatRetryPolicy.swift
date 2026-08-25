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
    /// unreachable. Beyond this the 5s heartbeat is the recovery — no
    /// unbounded retry loop.
    public static let maxConsecutiveRetries = 2

    /// Separate budget for terminal (End) re-sends. The terminal beat is the
    /// one with no subsequent heartbeat to recover it and the one #614 calls
    /// out ("End remains terminal under direct message, realtime echo,
    /// retry, foreground and late-live races"), so it pre-empts a pending
    /// non-terminal retry and ignores the consecutive-failure cap — but it
    /// is still bounded so a dead link can't retry forever (the durable
    /// `live_workouts` row written by `markEnded()` is the backstop).
    public static let maxEndRetries = 3

    /// Whether a failure of `event` should schedule another automatic send.
    ///
    /// - A terminal event retries whenever its own budget is left, ignoring
    ///   `retryInFlight` (it pre-empts a pending non-terminal retry) and the
    ///   consecutive-failure cap. Its re-send stays terminal and the phone's
    ///   terminal dominance rejects a late live packet, so a pre-empting End
    ///   can never resurrect the run.
    /// - Telemetry is never retried: the next heartbeat (≤5s) carries the
    ///   same state at a higher sequence, so an extra send buys nothing.
    /// - `retryInFlight` dedupes non-terminal re-sends to one at a time.
    /// - `consecutiveFailures` bounds the non-terminal burst; a success (the
    ///   phone's ack) resets it, so a healthy stretch never eats into the cap.
    public static func shouldRetry(
        event: LiveMirrorEvent,
        consecutiveFailures: Int,
        retryInFlight: Bool,
        endRetries: Int
    ) -> Bool {
        if event.isTerminal {
            return endRetries < maxEndRetries
        }
        return event.isDiscrete && !retryInFlight && consecutiveFailures < maxConsecutiveRetries
    }

    /// Whether a scheduled retry may still fire when the run's live sync actor
    /// is already gone (`liveSync == nil`). A TERMINAL re-send is safe and
    /// required then: `end()` tears `liveSync` down fast when `markEnded()`
    /// fails quickly (the #472 expired-token 401) — exactly when the durable
    /// fallback also failed, so the direct terminal beat is the last hope.
    /// Run identity (the retry closure's runId guard) still prevents a stale
    /// terminal beat from acting on a newer run, and phone-side terminal
    /// dominance keeps it from resurrecting the ended run. A non-terminal
    /// retry has nothing meaningful to re-send after teardown.
    public static func mayRetryWithoutLiveSync(event: LiveMirrorEvent) -> Bool {
        event.isTerminal
    }
}
