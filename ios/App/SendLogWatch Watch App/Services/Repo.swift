import Foundation
import Supabase

enum Repo {
    private static var client: SupabaseClient { SupabaseService.client }

    // MARK: Tindeq recordings (identical shape to the web app's inserts)

    static func insertTindeqRecording(
        _ r: StoppedRecording,
        note: String,
        tag: String,
        side: String,
        groupId: UUID?
    ) async throws {
        let row = TindeqRecordingInsert(
            durationMs: r.durationMs,
            peakKg: r.peakKg,
            avgKg: r.avgKg,
            sampleCount: r.samples.count,
            note: note,
            tag: tag,
            side: side,
            groupId: groupId,
            samples: r.samples.map { [$0.t, $0.kg] }
        )
        try await client.from("tindeq_recordings").insert(row).execute()
    }

    /// Distinct tags from recent recordings, most recently used first.
    static func fetchRecentTindeqTags() async throws -> [String] {
        let rows: [TindeqTagRow] = try await client
            .from("tindeq_recordings")
            .select("tag")
            .neq("tag", value: "")
            .order("recorded_at", ascending: false)
            .limit(100)
            .execute()
            .value
        var seen = Set<String>()
        var tags: [String] = []
        for r in rows where !seen.contains(r.tag) {
            seen.insert(r.tag)
            tags.append(r.tag)
        }
        return tags
    }

    /// Log a finished gauge session into the training log (mirrors the web
    /// app): type 'tindeq', load = duration × RPE feeds ACWR.
    static func logTindeqSession(
        durationMin: Int,
        rpe: Double,
        note: String,
        groupId: UUID
    ) async throws {
        let phase = (try? await fetchCurrentPhase()) ?? "capacity"
        let session = SessionInsert(
            id: UUID(),
            date: Date().localDateString,
            type: "tindeq",
            typeLabel: "Tindeq",
            durationMin: max(1, min(600, durationMin)),
            rpe: rpe,
            note: note,
            phase: phase,
            groupId: groupId,
            workoutSource: nil
        )
        try await client.from("sessions").insert(session).execute()
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

    static func fetchSessionLoads(sinceDays: Int) async throws -> [SessionLoadRow] {
        let cutoff = Calendar.gregorianLocal.date(byAdding: .day, value: -sinceDays, to: Date())!
        return try await client
            .from("sessions")
            .select("date, load")
            .gte("date", value: cutoff.localDateString)
            .execute()
            .value
    }

    /// Latest computed readiness row, written by the iPhone app. The watch
    /// only displays it — it no longer reads HealthKit or computes readiness.
    static func fetchLatestHealthMetric() async throws -> HealthMetricRow? {
        let rows: [HealthMetricRow] = try await client
            .from("health_metrics")
            .select("date, readiness, zone")
            .order("date", ascending: false)
            .limit(1)
            .execute()
            .value
        return rows.first
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
        rpe: Double,
        phase: String,
        tunables: Tunables
    ) -> WorkoutSaveBundle {
        let sessionId = UUID()
        // Reuse the id generated at workout start so the live_workouts row and
        // the final climb_workouts row share one id (web correlation).
        let workoutId = summary.workoutId
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
            phase: phase,
            groupId: nil,
            workoutSource: "watch"
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
                effortScore: a.effortScore,
                source: a.source.rawValue
            )
        }
        return WorkoutSaveBundle(session: session, workout: workout, attempts: attempts)
    }

    /// Best-effort mid-workout flush (SL-90) — merge-upserts the partial row.
    static func flushPartialWorkout(_ p: ClimbWorkoutPartialUpsert) async throws {
        try await client.from("climb_workouts")
            .upsert(p, onConflict: "id")
            .execute()
    }

    /// Three idempotent upserts (client-generated UUIDs) so offline-queue
    /// replays after partial success are safe. The workout row MERGES on
    /// conflict (not ignore) — the SL-90 periodic flush may have written a
    /// partial row under the same id, and the final stats must land over it.
    static func uploadBundle(_ bundle: WorkoutSaveBundle) async throws {
        try await client.from("sessions")
            .upsert(bundle.session, onConflict: "id", ignoreDuplicates: true)
            .execute()
        try await client.from("climb_workouts")
            .upsert(bundle.workout, onConflict: "id")
            .execute()
        if !bundle.attempts.isEmpty {
            try await client.from("climb_attempts")
                .upsert(bundle.attempts, onConflict: "id", ignoreDuplicates: true)
                .execute()
        }
    }
}
