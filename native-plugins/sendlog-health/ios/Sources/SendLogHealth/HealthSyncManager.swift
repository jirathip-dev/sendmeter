import Foundation
import HealthKit
import Supabase
import SendLogHealthCore

/// Snake_case rows matching PostgREST (mirror the watch's Models.swift so the
/// health_metrics upsert shape is identical). user_id is omitted — the DB
/// defaults it to auth.uid().
private struct HealthMetricsUpsert: Codable {
    var date: String
    var hrvSdnnMs: Double?
    var restingHr: Double?
    var sleepHours: Double?
    var sleepDeepHours: Double?
    var sleepRemHours: Double?
    var bodyMassKg: Double?
    var respRateBpm: Double?
    // Optional (not just "nullable in the DB"): when ReadinessWritePolicy
    // withholds today's score, these three are left OUT of the upsert
    // payload entirely (Codable's synthesized encodeIfPresent for Optional
    // properties omits nil keys rather than sending `null`), so Postgres'
    // ON CONFLICT DO UPDATE only touches the biometric columns above and
    // leaves the existing readiness/zone/computed_at untouched.
    var readiness: Int?
    var zone: String?
    var computedAt: Date?

    enum CodingKeys: String, CodingKey {
        case date, readiness, zone
        case hrvSdnnMs = "hrv_sdnn_ms"
        case restingHr = "resting_hr"
        case sleepHours = "sleep_hours"
        case sleepDeepHours = "sleep_deep_hours"
        case sleepRemHours = "sleep_rem_hours"
        case bodyMassKg = "body_mass_kg"
        case respRateBpm = "resp_rate_bpm"
        case computedAt = "computed_at"
    }
}

private struct SessionLoadRow: Codable {
    var date: String
    var load: Int?
}

/// Just enough of today's existing row to decide whether an automatic sync
/// may overwrite its readiness — see `ReadinessWritePolicy`. Deliberately
/// decodes `date` as a String (the DB `date` column, not a `timestamptz`)
/// rather than `computed_at` as a `Date` — a `timestamptz` decode mismatch
/// here must not be able to break this lookup (see the fail-open handling
/// in `syncNow`), and the policy only needs presence + the row's own date
/// for its self-defense check, not a timestamp.
private struct ExistingReadinessRow: Codable {
    var date: String
    var readiness: Int?
}

/// Orchestrates iPhone-side readiness: read HealthKit → ACWR from the user's
/// sessions → RecoveryEngine → upsert health_metrics. The iPhone is the sole
/// writer (the watch only reads the score back for display), so there's no
/// two-writer coordination to worry about.
final class HealthSyncManager {
    static let shared = HealthSyncManager()

    private let client = HealthConfig.data
    private let reader = HealthKitReader()
    private let tunables = RecoveryTunables.default
    private var observerStarted = false

    func requestAuthorization() async throws {
        try await reader.requestAuthorization()
    }

    /// Stores the relayed access token (#265). Purely local — no network call
    /// at all, where `auth.setSession` used to spend a `GET /user` on every
    /// relay (and refresh outright if the token it was handed had expired).
    func setSession(accessToken: String) {
        HealthSessionStore.shared.store(accessToken)
    }

    /// Forgets this client's stored token — called when the phone signs out,
    /// so a later background HealthKit wake can't keep writing as that user.
    /// Local only: the WebView's own signOut has already revoked the session
    /// server-side, and this client has no session of its own to end.
    func clearSession() {
        HealthSessionStore.shared.clear()
    }

    /// Read HealthKit, upsert today's biometrics, and — subject to
    /// `ReadinessWritePolicy` — (re)compute and upsert readiness/zone.
    ///
    /// `trigger` is required, not defaulted: `.manual` (an explicit
    /// user-refresh gesture — the app has none yet, reserved for a future
    /// pull-to-refresh) is always authoritative; `.automatic` (every
    /// existing call site today — cold-launch and foreground re-syncs are
    /// both app-driven, not user-initiated) defers to the policy. #109:
    /// an automatic sync can fire repeatedly through the day (background
    /// delivery, plus every app foreground), and several inputs — resting
    /// HR especially — aren't guaranteed finalized in the morning, so once
    /// today has a readiness, an automatic sync after noon leaves it alone.
    ///
    /// The biometric columns (hrv/rhr/sleep/resp/mass) are NOT gated by the
    /// policy and are always re-read + re-upserted on every call, locked or
    /// not — a metric HealthKit only finishes writing mid-afternoon (sleep
    /// stages are a common case) must still land in the row for that day.
    /// Readiness is the frozen morning score; the biometric columns stay
    /// current through the day.
    func syncNow(trigger: SyncTrigger) async throws {
        let today = Date().localDateString

        var allowReadinessOverwrite = true
        if trigger == .automatic {
            // Fail OPEN: a network blip or a decode mismatch here must not
            // silently turn the whole sync into a no-op — that would leave
            // the day without ANY score, which is worse than the intraday
            // drift this policy exists to fix. Unknown state defaults to
            // "not yet locked", matching pre-#109 (always-overwrite)
            // behavior.
            let existing: [ExistingReadinessRow] = (try? await client
                .from("health_metrics")
                .select("date, readiness")
                .eq("date", value: today)
                .execute()
                .value) ?? []
            allowReadinessOverwrite = ReadinessWritePolicy.shouldOverwriteReadiness(
                existingReadiness: existing.first?.readiness,
                existingRowDate: existing.first?.date,
                now: Date(),
                trigger: .automatic
            )
        }

        let inputs = try await reader.readToday()

        var row = HealthMetricsUpsert(
            date: today,
            hrvSdnnMs: inputs.hrvSDNNms,
            restingHr: inputs.restingHR,
            sleepHours: inputs.sleepHours,
            sleepDeepHours: inputs.sleepDeepHours,
            sleepRemHours: inputs.sleepRemHours,
            bodyMassKg: inputs.bodyMassKg,
            respRateBpm: inputs.respRateBpm,
            readiness: nil,
            zone: nil,
            computedAt: nil
        )
        if allowReadinessOverwrite {
            let acwr = try? await computeAcwr()
            let result = RecoveryEngine.compute(inputs: inputs, acwr: acwr, t: tunables)
            row.readiness = result.score
            row.zone = result.zone?.rawValue
            row.computedAt = Date()
        }

        try await client
            .from("health_metrics")
            .upsert(row, onConflict: "user_id,date")
            .execute()
    }

    /// Hard-delete the user's health rows (RLS scopes to auth.uid()), then
    /// rebuild the whole recent history from HealthKit — not just today — so a
    /// clear recovers the full readiness trend, not a single day. Days with no
    /// health signal are skipped rather than written as empty rows. Explicit
    /// user action (the "Clear & resync" setting) — always authoritative,
    /// doesn't consult `ReadinessWritePolicy`.
    func clearAndResync(historyDays: Int = 90) async throws {
        try await client
            .from("health_metrics")
            .delete()
            .gte("date", value: "2000-01-01")
            .execute()

        let history = try await reader.readHistory(days: historyDays)
        let acwrByDate = (try? await acwrSeries(days: historyDays)) ?? [:]

        var rows: [HealthMetricsUpsert] = []
        for day in history {
            let i = day.inputs
            guard i.hrvSDNNms != nil || i.restingHR != nil || i.sleepHours != nil
            else { continue }
            let result = RecoveryEngine.compute(
                inputs: i, acwr: acwrByDate[day.date], t: tunables
            )
            rows.append(HealthMetricsUpsert(
                date: day.date,
                hrvSdnnMs: i.hrvSDNNms,
                restingHr: i.restingHR,
                sleepHours: i.sleepHours,
                sleepDeepHours: i.sleepDeepHours,
                sleepRemHours: i.sleepRemHours,
                bodyMassKg: i.bodyMassKg,
                respRateBpm: i.respRateBpm,
                readiness: result.score,
                zone: result.zone?.rawValue,
                computedAt: Date()
            ))
        }
        guard !rows.isEmpty else { return }
        try await client
            .from("health_metrics")
            .upsert(rows, onConflict: "user_id,date")
            .execute()
    }

    /// ACWR as-of each of the trailing `days`, keyed by that day's date string.
    /// One session-loads fetch spanning the whole window feeds a per-day EWMA,
    /// so a backfilled history row gets the load ratio it would have had that
    /// day (not today's) — the load penalty then reflects the real timeline.
    private func acwrSeries(days: Int) async throws -> [String: Double] {
        // #487 (F1): exclude soft-deleted sessions — without this the load
        // penalty from training the user deleted (History's soft-delete,
        // `deleted_at`) kept depressing readiness for the rest of the 28-day
        // ACWR window. The web's equivalent query (src/lib/repo/sessions.ts
        // fetchSessions) has always filtered this; native didn't, so the two
        // surfaces disagreed about what counts.
        let rows: [SessionLoadRow] = try await client
            .from("sessions")
            .select("date, load")
            .gte("date", value: cutoffDateString(daysAgo: days + Acwr.lookbackDays))
            .is("deleted_at", value: nil)
            .execute()
            .value

        var loadByDate: [String: Int] = [:]
        for r in rows { loadByDate[r.date, default: 0] += (r.load ?? 0) }

        let cal = Calendar.gregorianLocal
        var result: [String: Double] = [:]
        for o in 0..<days {
            let endDay = cal.date(byAdding: .day, value: -o, to: Date())!
            var series: [Double] = []
            for i in stride(from: Acwr.lookbackDays - 1, through: 0, by: -1) {
                let d = cal.date(byAdding: .day, value: -i, to: endDay)!
                series.append(Double(loadByDate[d.localDateString] ?? 0))
            }
            if let ratio = Acwr.ratio(dailyLoads: series) {
                result[endDay.localDateString] = ratio
            }
        }
        return result
    }

    private func computeAcwr() async throws -> Double? {
        // #487 (F1): same soft-delete exclusion as acwrSeries above.
        let rows: [SessionLoadRow] = try await client
            .from("sessions")
            .select("date, load")
            .gte("date", value: cutoffDateString(daysAgo: Acwr.lookbackDays))
            .is("deleted_at", value: nil)
            .execute()
            .value

        var loadByDate: [String: Int] = [:]
        for r in rows { loadByDate[r.date, default: 0] += (r.load ?? 0) }

        let cal = Calendar.gregorianLocal
        var dailyLoads: [Double] = []
        for i in stride(from: Acwr.lookbackDays - 1, through: 0, by: -1) {
            let day = cal.date(byAdding: .day, value: -i, to: Date())!
            dailyLoads.append(Double(loadByDate[day.localDateString] ?? 0))
        }
        return Acwr.ratio(dailyLoads: dailyLoads)
    }

    private func cutoffDateString(daysAgo: Int) -> String {
        let cutoff = Calendar.gregorianLocal.date(byAdding: .day, value: -daysAgo, to: Date())!
        return cutoff.localDateString
    }

    // MARK: Background delivery

    /// Register an HKObserverQuery + background delivery so new wearable data
    /// wakes the app and triggers a sync automatically. Idempotent.
    func startBackgroundSync() {
        guard !observerStarted, HKHealthStore.isHealthDataAvailable() else { return }
        observerStarted = true
        let store = reader.healthStore

        let query = HKObserverQuery(
            sampleType: HealthKitReader.observedType, predicate: nil
        ) { [weak self] _, completion, _ in
            Task {
                // #109: this fires on every HealthKit background wake, not
                // on user action — always .automatic, so ReadinessWritePolicy
                // gets a say before today's row is touched.
                try? await self?.syncNow(trigger: .automatic)
                completion()
            }
        }
        store.execute(query)
        store.enableBackgroundDelivery(
            for: HealthKitReader.observedType, frequency: .daily
        ) { _, _ in }
    }
}
