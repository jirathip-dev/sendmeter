import Foundation

/// Issue #147: the watch's tag-fetch retry loop in `ForceGaugeView` used to
/// get stuck showing "Loading exercises…" for minutes when the Progressor
/// connect happened at the same time — the fetch is proxied over the BLE
/// link to the phone, and while CoreBluetooth is scanning/connecting the
/// radio is congested enough that a plain request routinely stalls for
/// URLSession's ~60s default timeout, and a connect event used to cancel and
/// restart that fetch from attempt 0 right when the radio was busiest. The
/// pure decisions are pulled out here so they're unit-testable without a
/// SwiftUI/network harness; `ForceGaugeView.loadTags` is the only caller.
public enum TagFetchPolicy {
    /// Attempts are 0-indexed, 4 total (0...3).
    public static let maxAttempts = 4

    /// Per-attempt network timeout — short enough that a BLE-congested
    /// request fails fast into the existing backoff instead of pinning the
    /// spinner for URLSession's ~60s default.
    public static let perAttemptTimeoutSeconds: Double = 6

    /// Backoff before the next attempt, or nil once there's no successor
    /// attempt left to wait for — sleeping after the final attempt only adds
    /// a pointless tail before the empty/Retry state can show.
    public static func sleepSeconds(afterAttempt attempt: Int) -> Double? {
        guard attempt < maxAttempts - 1 else { return nil }
        return Double(attempt + 1) * 1.5
    }

    /// A connect is meant to be a fresh chance to win the tag fetch (the auth
    /// relay may have settled since launch) — but only when nothing is
    /// already in flight. Cancelling and restarting a fetch that's mid-retry
    /// resets its backoff to attempt 0 at exactly the moment the BLE radio is
    /// busiest connecting to the Progressor, which is how the fetch got stuck
    /// in the first place. A fetch that already finished empty still
    /// restarts on connect, preserving the "connect is a fresh chance" intent.
    public static func shouldRestartOnConnect(hasTags: Bool, inFlight: Bool) -> Bool {
        !hasTags && !inFlight
    }
}

/// Thrown by `withTimeout` when `operation` doesn't finish within `seconds`.
public struct TimeoutError: Error, Sendable {
    public init() {}
}

/// Races `operation` against a `seconds` deadline using structured
/// concurrency; whichever finishes first wins and the other is cancelled.
/// `operation` is expected to honor cooperative cancellation the way
/// URLSession's async APIs do, so a timed-out request is actually torn down
/// rather than left running in the background.
public func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }
        guard let result = try await group.next() else {
            throw TimeoutError()
        }
        group.cancelAll()
        return result
    }
}
