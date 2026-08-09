import Foundation
import SendLogWatchCore
import Supabase

/// Best-effort live heartbeat so the web Workout tab can mirror an
/// in-progress watch workout (SL-41). WatchConnectivity is the immediate
/// path; this actor is the durable Supabase fallback.
///
/// The actor owns both the monotonic cursor and the coalescing drain (#521):
/// - a duplicate/out-of-order beat is rejected before the first `await`;
/// - telemetry arriving while a request is in flight replaces the pending
///   snapshot with the latest one;
/// - a terminal row replaces pending telemetry and is never replaced by a
///   later live beat;
/// - End waits behind the in-flight request, so it cannot be overwritten by a
///   late provisional heartbeat.
/// End AND Discard call `markEnded()` (status='ended') rather than deleting —
/// postgres_changes can't filter DELETE events on the web side.
actor LiveWorkoutSync {
    private let workoutId: UUID
    private let startedAt: Date
    private var userId: UUID?
    private var latestSequence = 0
    private var terminalQueued = false
    private var pending: LiveWorkoutUpsert?
    private var pendingIdentity = LiveMirrorPendingIdentity()
    private var draining = false

    init(workoutId: UUID, startedAt: Date) {
        self.workoutId = workoutId
        self.startedAt = startedAt
    }

    /// Reads the relayed account synchronously. `WatchSessionStore` is
    /// lock-backed and deliberately exposes synchronous reads, so there is
    /// no reason to suspend here and let an older beat mutate a newer
    /// `pending` row after the lookup returns.
    private func resolveUserId() -> UUID? {
        if let userId { return userId }
        // The relayed session's `sub` claim (#265). No auth client is
        // involved, so there is no accessor here that could refresh anything.
        userId = WatchSessionStore.shared.userId
        return userId
    }

    /// Enqueue one live snapshot. Sequence validation and pending replacement
    /// happen before the user-id lookup/transport await, so a re-entrant actor
    /// call cannot make a stale closure decide the current row.
    func beat(
        hr: Double?,
        attemptCount: Int,
        activeKcal: Double?,
        elevationGainM: Double,
        climbing: Bool,
        climbingSince: Date?,
        restStartedAt: Date?,
        restTargetS: Int?,
        sequence: Int,
        event: LiveMirrorEvent,
        terminal: Bool = false
    ) async {
        guard sequence > latestSequence else { return }
        guard !terminalQueued else { return }
        latestSequence = sequence
        let isTerminal = terminal || event.isTerminal
        if isTerminal { terminalQueued = true }
        pending = LiveWorkoutUpsert(
            userId: UUID(), // replaced below once the relayed session is known
            workoutId: workoutId,
            runId: workoutId,
            sequence: sequence,
            event: event.rawValue,
            terminal: isTerminal,
            status: isTerminal ? "ended" : "live",
            startedAt: startedAt,
            hr: hr,
            attemptCount: attemptCount,
            activeKcal: activeKcal,
            elevationGainM: elevationGainM,
            climbing: climbing,
            climbingSince: climbingSince,
            restStartedAt: restStartedAt,
            restTargetS: restTargetS,
            updatedAt: Date()
        )
        pendingIdentity.replace(withSequence: sequence)
        guard let uid = resolveUserId() else {
            // A future async lookup must not clear a row installed by a newer
            // beat. Keep this identity check even though the current store
            // read is synchronous: it makes the invariant explicit and
            // prevents a later refactor from reopening this race.
            if pendingIdentity.clear(ifSequence: sequence) {
                pending = nil
                if isTerminal { terminalQueued = false }
            }
            // Keep a terminal transition retryable when the relayed access
            // token is temporarily unavailable. The sequence claim still
            // rejects the same packet if it is replayed, while a later
            // markEnded() can claim a fresh terminal sequence and preserve
            // the durable end rather than leaving the actor permanently
            // closed with no row on Supabase.
            return
        }
        guard pendingIdentity.matches(sequence: sequence) else {
            // This invocation lost ownership of pending to a newer beat. The
            // newer invocation owns both user-id resolution and the drain;
            // returning here also prevents an older successful lookup from
            // sending the newer row while it still contains its placeholder
            // user id.
            return
        }
        pending?.userId = uid
        await drain()
    }

    /// Mark the live row ended (called from End and Discard). This method is
    /// retained as the defensive fallback for callers that do not already
    /// allocate a terminal `LiveMirrorBeat`; it still claims the next
    /// sequence synchronously before any await.
    func markEnded() async {
        guard !terminalQueued else {
            await drain()
            return
        }
        // Int.max is a valid sequence exactly once. There is no representable
        // successor, so fail closed instead of saturating and emitting a
        // duplicate terminal sequence.
        guard latestSequence < Int.max else { return }
        latestSequence += 1
        let endSequence = latestSequence
        terminalQueued = true
        pending = LiveWorkoutUpsert(
            userId: UUID(),
            workoutId: workoutId,
            runId: workoutId,
            sequence: endSequence,
            event: LiveMirrorEvent.end.rawValue,
            terminal: true,
            status: "ended",
            startedAt: startedAt,
            hr: nil,
            attemptCount: 0,
            activeKcal: nil,
            elevationGainM: nil,
            climbing: false,
            climbingSince: nil,
            restStartedAt: nil,
            restTargetS: nil,
            updatedAt: Date()
        )
        pendingIdentity.replace(withSequence: endSequence)
        guard let uid = resolveUserId() else {
            if pendingIdentity.clear(ifSequence: endSequence) {
                pending = nil
                terminalQueued = false
            }
            return
        }
        guard pendingIdentity.matches(sequence: endSequence) else {
            // A newer owner (if this lookup ever becomes asynchronous) must
            // stamp and drain its own row; never send its placeholder here.
            return
        }
        pending?.userId = uid
        await drain()
    }

    /// One serial drain. Actor re-entrancy lets later beats replace `pending`
    /// while `upsert` is suspended; the loop picks up that latest snapshot
    /// after the current request returns.
    private func drain() async {
        guard !draining else { return }
        draining = true
        while let row = pending {
            pending = nil
            // Do not clear a newer identity that may have replaced this row
            // while the previous upsert was suspended.
            _ = pendingIdentity.clear(ifSequence: row.sequence)
            await upsert(row)
        }
        draining = false
    }

    private func upsert(_ row: LiveWorkoutUpsert) async {
        try? await SupabaseService
            .from("live_workouts")
            .upsert(row, onConflict: "user_id")
            .execute()
    }
}
