import Foundation

// MARK: - Realtime list reconciliation (native port of the web's
// src/components/RealtimeVersionProvider.tsx WATCHED_TABLES contract)

/// Every table a watch (or another device) write can touch, subscribed per
/// user with a `user_id=eq.<me>` filter. `live_workouts` is deliberately NOT
/// here — it feeds the dedicated mirror channel (AppModel's live workout
/// state), never list reconciliation, so the watch's ~5s heartbeat can never
/// trigger a refetch of every list.
public enum RealtimeTable: String, CaseIterable, Sendable {
    case sessions
    case tindeqRecordings = "tindeq_recordings"
    case climbWorkouts = "climb_workouts"
    case climbAttempts = "climb_attempts"
    case healthMetrics = "health_metrics"
}

/// The AppModel data slice refreshed when a watched table changes. One slice
/// may be fed by more than one table (a `climb_attempts` write changes the
/// workout list's embedded attempts too).
public enum ReconcileSlice: String, CaseIterable, Hashable, Sendable {
    /// The sessions list (Dashboard ACWR, History timeline, Home banner).
    case sessions
    /// The Tindeq recordings list (Force references, History recordings).
    case recordings
    /// The climb workout list (History workout entries + embedded attempts).
    case workouts
    /// The readiness/health metrics (Dashboard).
    case health
}

/// "Given a realtime event for table X, which slice refreshes" — the pure
/// decision behind scope item 2. Unknown tables (including `live_workouts`)
/// map to nil so they can never schedule a reconciliation.
public func reconcileSlice(for table: RealtimeTable) -> ReconcileSlice {
    switch table {
    case .sessions: return .sessions
    case .tindeqRecordings: return .recordings
    case .climbWorkouts, .climbAttempts: return .workouts
    case .healthMetrics: return .health
    }
}

public func reconcileSlice(for tableName: String) -> ReconcileSlice? {
    RealtimeTable(rawValue: tableName).map(reconcileSlice(for:))
}

/// Coalesces realtime list events into one targeted refresh per quiet window
/// (default 400ms, matching the web's coalesce-bursts behavior — the web bumps
/// a version and consumers refetch once per render; native schedules the
/// refresh once per debounce window). Pure and clock-injectable so the
/// decision is unit-tested without any network.
public final class RealtimeRefreshCoalescer: @unchecked Sendable {
    public let debounceIntervalMs: TimeInterval
    private let lock = NSLock()
    private var pending: Set<ReconcileSlice> = []
    private var lastEventAtMs: TimeInterval?

    public init(debounceIntervalMs: TimeInterval = 400) {
        self.debounceIntervalMs = debounceIntervalMs
    }

    /// Records a slice as needing a refresh and returns the full pending set.
    /// Trailing-edge: the quiet window is measured from THIS event, so a
    /// burst of events collapses into one flush.
    @discardableResult
    public func record(_ slice: ReconcileSlice, atMs: TimeInterval) -> Set<ReconcileSlice> {
        lock.lock()
        defer { lock.unlock() }
        pending.insert(slice)
        lastEventAtMs = atMs
        return pending
    }

    /// The pending slices, ready only once the debounce window has elapsed
    /// since the LAST event. Returns nil while the window is still open so a
    /// caller can keep waiting without losing the burst.
    public func takeReadySlices(atMs: TimeInterval) -> Set<ReconcileSlice>? {
        lock.lock()
        defer { lock.unlock() }
        guard let lastEventAtMs, atMs - lastEventAtMs >= debounceIntervalMs else { return nil }
        let ready = pending
        pending.removeAll()
        self.lastEventAtMs = nil
        return ready.isEmpty ? nil : ready
    }

    /// Milliseconds until the current window closes (0 when idle). Lets a
    /// waiting task sleep exactly as long as needed and re-check.
    public func remainingMs(atMs: TimeInterval) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard let lastEventAtMs else { return 0 }
        return max(0, lastEventAtMs + debounceIntervalMs - atMs)
    }

    public var isWaiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending.isEmpty == false
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        pending = []
        lastEventAtMs = nil
    }
}
