import Foundation
import Supabase

/// Best-effort live heartbeat so the web Workout tab can mirror an
/// in-progress watch workout (SL-41). Fire-and-forget by design:
/// - Never blocks the workout and never touches the OfflineQueue — the live
///   mirror is inherently online-only; a missed beat just means the web shows
///   slightly stale data (and treats >30s silence as a dead watch).
/// - Skips a beat while a previous upsert is still in flight, so a slow
///   network can't queue up beats.
/// End AND Discard call `markEnded()` (status='ended') rather than deleting —
/// postgres_changes can't filter DELETE events on the web side.
actor LiveWorkoutSync {
    private let workoutId: UUID
    private let startedAt: Date
    private var userId: UUID?
    private var inFlight = false

    init(workoutId: UUID, startedAt: Date) {
        self.workoutId = workoutId
        self.startedAt = startedAt
    }

    private func resolveUserId() async -> UUID? {
        if let userId { return userId }
        // The relayed session's `sub` claim (#265). No auth client is
        // involved, so there is no accessor here that could refresh anything.
        userId = WatchSessionStore.shared.userId
        return userId
    }

    func beat(
        hr: Double?,
        attemptCount: Int,
        activeKcal: Double?,
        elevationGainM: Double,
        climbing: Bool,
        climbingSince: Date?,
        restStartedAt: Date?,
        restTargetS: Int?
    ) async {
        if inFlight { return }
        guard let uid = await resolveUserId() else { return }
        inFlight = true
        defer { inFlight = false }
        await upsert(
            LiveWorkoutUpsert(
                userId: uid,
                workoutId: workoutId,
                status: "live",
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
        )
    }

    /// Mark the live row ended (called from End and Discard). Bypasses the
    /// in-flight guard — this is the final, important write.
    func markEnded() async {
        guard let uid = await resolveUserId() else { return }
        await upsert(
            LiveWorkoutUpsert(
                userId: uid,
                workoutId: workoutId,
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
        )
    }

    private func upsert(_ row: LiveWorkoutUpsert) async {
        try? await SupabaseService.data
            .from("live_workouts")
            .upsert(row, onConflict: "user_id")
            .execute()
    }
}
