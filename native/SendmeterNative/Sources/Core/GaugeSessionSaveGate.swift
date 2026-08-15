import Foundation

/// Tracks how many per-rep durable saves are still in flight so the
/// session-end path can wait for the final rep before snapshotting (the
/// native analog of the web's `RepSettlement` in `gaugeSessionEnd.ts`,
/// #613). `begin()` MUST run synchronously before the save's first await;
/// `finish()` runs once the rep is durable on-device and locally published —
/// never when the network insert completes, so the wait is bounded by local
/// storage latency, not the network.
public actor GaugeSessionSaveGate {
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func begin() {
        inFlight += 1
    }

    public func finish() {
        inFlight = max(0, inFlight - 1)
        if inFlight == 0 {
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    public func waitForIdle() async {
        guard inFlight > 0 else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public var pendingCount: Int { inFlight }
}
