import Foundation
import Supabase

enum Repo {
    private static var client: SupabaseClient { SupabaseService.client }

    // MARK: Tindeq recordings (identical shape to the web app's inserts)

    static func insertTindeqRecording(_ r: StoppedRecording, note: String) async throws {
        let row = TindeqRecordingInsert(
            durationMs: r.durationMs,
            peakKg: r.peakKg,
            avgKg: r.avgKg,
            sampleCount: r.samples.count,
            note: note,
            samples: r.samples.map { [$0.t, $0.kg] }
        )
        try await client.from("tindeq_recordings").insert(row).execute()
    }

    // MARK: Confirmed workout → sessions + climb_workouts + climb_attempts

    static func fetchCurrentPhase() async throws -> String {
        let rows: [UserSettingsRow] = try await client
            .from("user_settings")
            .select("current_phase")
            .execute()
            .value
        return rows.first?.currentPhase ?? "capacity"
    }

    static func fetchLabeledWorkouts() async throws -> [LabeledWorkoutRow] {
        try await client
            .from("climb_workouts")
            .select("avg_hr, mean_effort, attempts_per_10min, rpe_confirmed")
            .not("rpe_confirmed", operator: .is, value: "null")
            .not("mean_effort", operator: .is, value: "null")
            .order("started_at", ascending: false)
            .limit(200)
            .execute()
            .value
    }

    static func makeSaveBundle(
        summary: WorkoutSummary,
        boulders: Int,
        rpe: Int,
        phase: String,
        tunables: Tunables
    ) -> WorkoutSaveBundle {
        let sessionId = UUID()
        let workoutId = UUID()
        let durationS = summary.endedAt.timeIntervalSince(summary.startedAt)
        let minutes = max(1, min(600, Int((durationS / 60).rounded())))
        let meanEffort = summary.attempts.isEmpty
            ? 0.0
            : summary.attempts.map(\.effortScore).reduce(0, +) / Double(summary.attempts.count)
        let attemptsPer10min = durationS > 0
            ? Double(summary.attempts.count) / (durationS / 600.0)
            : 0.0

        var noteParts = ["\(boulders) boulder\(boulders == 1 ? "" : "s")"]
        if let hr = summary.avgHR, hr > 0 { noteParts.append("avg HR \(Int(hr.rounded()))") }
        if summary.elevationGainM > 0 { noteParts.append("+\(Int(summary.elevationGainM.rounded()))m") }

        let session = SessionInsert(
            id: sessionId,
            date: summary.startedAt.localDateString,
            type: "auto",
            typeLabel: "Auto-tracked",
            durationMin: minutes,
            rpe: rpe,
            note: noteParts.joined(separator: " · "),
            phase: phase
        )
        let workout = ClimbWorkoutInsert(
            id: workoutId,
            startedAt: summary.startedAt,
            endedAt: summary.endedAt,
            avgHr: summary.avgHR,
            maxHr: summary.maxHR,
            activeKcal: summary.activeKcal,
            elevationGainM: summary.elevationGainM,
            attemptsDetected: summary.attempts.count,
            attemptsConfirmed: boulders,
            rpePredicted: (summary.predictedRPE * 10).rounded() / 10,
            rpeConfirmed: rpe,
            meanEffort: (meanEffort * 100).rounded() / 100,
            attemptsPer10min: (attemptsPer10min * 100).rounded() / 100,
            sessionId: sessionId,
            raw: tunables.keepRawTrace ? summary.rawTrace : nil
        )
        let attempts = summary.attempts.map { a in
            ClimbAttemptInsert(
                id: UUID(),
                workoutId: workoutId,
                startedAt: a.startedAt,
                durationS: a.durationS,
                elevationGainM: a.elevationGainM,
                avgHr: a.avgHR,
                peakHr: a.peakHR,
                motionIntensity: a.motionIntensity,
                effortScore: a.effortScore
            )
        }
        return WorkoutSaveBundle(session: session, workout: workout, attempts: attempts)
    }

    /// Three idempotent upserts (client-generated UUIDs) so offline-queue
    /// replays after partial success are safe.
    static func uploadBundle(_ bundle: WorkoutSaveBundle) async throws {
        try await client.from("sessions")
            .upsert(bundle.session, onConflict: "id", ignoreDuplicates: true)
            .execute()
        try await client.from("climb_workouts")
            .upsert(bundle.workout, onConflict: "id", ignoreDuplicates: true)
            .execute()
        if !bundle.attempts.isEmpty {
            try await client.from("climb_attempts")
                .upsert(bundle.attempts, onConflict: "id", ignoreDuplicates: true)
                .execute()
        }
    }
}
