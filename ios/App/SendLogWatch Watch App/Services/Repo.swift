import Foundation
import SendLogWatchCore
import Supabase

enum Repo {
    private static var client: SupabaseClient { SupabaseService.data }

    // MARK: Tindeq recordings (identical shape to the web app's inserts)

    /// Builds the insert row from a stopped recording (#486) — pulled out of
    /// `insertTindeqRecording` so `PendingRecordingQueue`'s callers can build
    /// the durable payload synchronously, before ever touching the network.
    /// `id` is minted by the caller (not defaulted here) so the SAME id is
    /// what gets persisted to disk and later replayed — a fresh `UUID()` per
    /// retry would defeat the idempotent upsert below.
    static func makeTindeqRecordingRow(
        _ r: StoppedRecording,
        id: UUID,
        note: String,
        tag: String,
        side: String,
        groupId: UUID?
    ) -> TindeqRecordingInsert {
        TindeqRecordingInsert(
            id: id,
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
    }

    /// Idempotent upsert on the client-minted id (#486) — safe for
    /// `PendingRecordingQueue` to replay after a response was lost. Mirrors
    /// `uploadBundle`/`logTindeqSession`'s `ignoreDuplicates` pattern: a
    /// retry that lands after the original insert already succeeded is a
    /// no-op rather than a duplicate row.
    static func insertTindeqRecording(_ row: TindeqRecordingInsert) async throws {
        try await client.from("tindeq_recordings")
            .upsert(row, onConflict: "id", ignoreDuplicates: true)
            .execute()
    }

    /// Distinct tags from recent recordings, most recently used first, minus
    /// any hidden via the `tindeq_tags` registry (SL-92/SL-94) — mirrors the
    /// web/iPhone Force-tab pickers (the registry read + client-side filter
    /// in `src/components/ForceView.tsx`). A renamed tag simply never shows
    /// up here under its old name (the rename repoints every recording), so
    /// no separate rename handling is needed on the read side.
    ///
    /// Each tag carries its persisted force curve (#280) — the SAME registry
    /// select that already fetched the hidden flags now also pulls `cf_kg` /
    /// `w_prime_kgs`, so the RPE prediction costs no extra round trip. The
    /// watch never fits a curve (that needs the raw sample streams, which it
    /// doesn't keep); it only reads the two numbers back.
    static func fetchRecentTindeqTags() async throws -> [TindeqTagInfo] {
        async let recordingsTask: [TindeqTagRow] = client
            .from("tindeq_recordings")
            .select("tag")
            .neq("tag", value: "")
            .order("recorded_at", ascending: false)
            .limit(100)
            .execute()
            .value
        async let registryTask: [TagRegistryRow] = fetchTagRegistry()

        let rows = try await recordingsTask
        let registry = try await registryTask
        let hidden = Set(registry.filter(\.hidden).map(\.name))
        let curves = Dictionary(registry.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        var seen = Set<String>()
        var tags: [TindeqTagInfo] = []
        for r in rows where !seen.contains(r.tag) && !hidden.contains(r.tag) {
            seen.insert(r.tag)
            tags.append(
                TindeqTagInfo(name: r.tag, cf: curves[r.tag]?.cfKg, wPrime: curves[r.tag]?.wPrimeKgs)
            )
        }
        return tags
    }

    /// The user's whole `tindeq_tags` registry (SL-92 hidden flags + #280
    /// curve params). Small by construction — one row per tag the user has
    /// ever hidden or fitted a curve for.
    static func fetchTagRegistry() async throws -> [TagRegistryRow] {
        try await client
            .from("tindeq_tags")
            .select("name, hidden, cf_kg, w_prime_kgs")
            .execute()
            .value
    }

    /// Log a finished gauge session into the training log (mirrors the web
    /// app): type 'tindeq', load = duration × RPE feeds ACWR. Takes the
    /// already-persisted `PendingTindeqSession` from `PendingSessionQueue`
    /// (issue #144) — date/duration/note were captured at "Log Session" tap
    /// time, so a delayed drain still logs against the moment the session
    /// actually finished. Phase is resolved here (at drain time) rather than
    /// at enqueue time since it's a cheap re-fetch and rarely stale.
    /// Idempotent upsert on the client-minted id so offline-queue replays
    /// after partial success are safe (same pattern as `uploadBundle`).
    static func logTindeqSession(_ pending: PendingTindeqSession) async throws {
        let phase = (try? await fetchCurrentPhase()) ?? "capacity"
        let session = SessionInsert(
            id: pending.id,
            date: pending.date,
            type: "tindeq",
            typeLabel: "Tindeq",
            durationMin: max(1, min(600, pending.durationMin)),
            rpe: pending.rpe,
            // #280: the watch predicts this RPE from W' depletion and logs
            // without asking, so it is unreviewed by definition (#114's
            // column). `nil` means a legacy queued item whose RPE the user
            // typed into the old finish sheet — that one IS confirmed.
            rpeConfirmed: pending.rpeConfirmed ?? true,
            note: pending.note,
            phase: phase,
            groupId: pending.groupId,
            workoutSource: nil
        )
        try await client.from("sessions")
            .upsert(session, onConflict: "id", ignoreDuplicates: true)
            .execute()
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
            // #487 (F1): exclude soft-deleted sessions from the on-watch ACWR
            // used by WidgetBridge — same fix as the iPhone health plugin's
            // acwrSeries/computeAcwr (HealthSyncManager.swift). Without this a
            // deleted session kept depressing the widget's ACWR for the rest
            // of the 28-day window even though it no longer counts anywhere
            // else in the app.
            .is("deleted_at", value: nil)
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
            rpePredicted: RPEQuantization.autoTracked(summary.predictedRPE),
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
