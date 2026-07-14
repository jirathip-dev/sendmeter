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
    var readiness: Int?
    var zone: String?
    var computedAt: Date

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

/// Orchestrates iPhone-side readiness: read HealthKit → ACWR from the user's
/// sessions → RecoveryEngine → upsert health_metrics. The iPhone is the sole
/// writer (the watch only reads the score back for display), so there's no
/// two-writer coordination to worry about.
final class HealthSyncManager {
    static let shared = HealthSyncManager()

    private let client = HealthConfig.client
    private let reader = HealthKitReader()
    private let tunables = RecoveryTunables.default
    private var observerStarted = false

    func requestAuthorization() async throws {
        try await reader.requestAuthorization()
    }

    func setSession(accessToken: String, refreshToken: String) async throws {
        try await client.auth.setSession(accessToken: accessToken, refreshToken: refreshToken)
    }

    /// Read HealthKit, compute today's readiness, upsert one row.
    func syncNow() async throws {
        let inputs = try await reader.readToday()
        let acwr = try? await computeAcwr()
        let result = RecoveryEngine.compute(inputs: inputs, acwr: acwr, t: tunables)

        let row = HealthMetricsUpsert(
            date: Date().localDateString,
            hrvSdnnMs: inputs.hrvSDNNms,
            restingHr: inputs.restingHR,
            sleepHours: inputs.sleepHours,
            sleepDeepHours: inputs.sleepDeepHours,
            sleepRemHours: inputs.sleepRemHours,
            bodyMassKg: inputs.bodyMassKg,
            respRateBpm: inputs.respRateBpm,
            readiness: result.score,
            zone: result.zone?.rawValue,
            computedAt: Date()
        )
        try await client
            .from("health_metrics")
            .upsert(row, onConflict: "user_id,date")
            .execute()
    }

    /// Hard-delete the user's health rows (RLS scopes to auth.uid()), then
    /// rebuild the whole recent history from HealthKit — not just today — so a
    /// clear recovers the full readiness trend, not a single day. Days with no
    /// health signal are skipped rather than written as empty rows.
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
        let rows: [SessionLoadRow] = try await client
            .from("sessions")
            .select("date, load")
            .gte("date", value: cutoffDateString(daysAgo: days + Acwr.lookbackDays))
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
        let rows: [SessionLoadRow] = try await client
            .from("sessions")
            .select("date, load")
            .gte("date", value: cutoffDateString(daysAgo: Acwr.lookbackDays))
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
                try? await self?.syncNow()
                completion()
            }
        }
        store.execute(query)
        store.enableBackgroundDelivery(
            for: HealthKitReader.observedType, frequency: .daily
        ) { _, _ in }
    }
}
