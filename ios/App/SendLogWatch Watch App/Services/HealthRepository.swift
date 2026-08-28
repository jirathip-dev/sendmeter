import Foundation
import SendLogWatchCore
import Supabase

// MARK: - Issue #802 — watch HealthKit sync repository surface

/// Full-window `health_metrics` row as fetched for reconciliation. The
/// display-only `HealthMetricRow` (date/readiness/zone) stays for the
/// tiny stored-row fetch; this row carries the biometrics the precedence
/// and #801 has-source-data rules need.
nonisolated struct HealthWindowRow: Codable {
    var date: String
    var readiness: Int?
    var zone: String?
    var computedAt: Date?
    var hrvSDNNMilliseconds: Double?
    var restingHeartRate: Double?
    var sleepHours: Double?
    var sleepDeepHours: Double?
    var sleepREMHours: Double?
    var bodyMassKilograms: Double?
    var respiratoryRate: Double?

    enum CodingKeys: String, CodingKey {
        case date, readiness, zone
        case computedAt = "computed_at"
        case hrvSDNNMilliseconds = "hrv_sdnn_ms"
        case restingHeartRate = "resting_hr"
        case sleepHours = "sleep_hours"
        case sleepDeepHours = "sleep_deep_hours"
        case sleepREMHours = "sleep_rem_hours"
        case bodyMassKilograms = "body_mass_kg"
        case respiratoryRate = "resp_rate_bpm"
    }

    var metric: WatchHealthMetric {
        WatchHealthMetric(
            date: date,
            readiness: readiness,
            zone: zone,
            computedAt: computedAt,
            hrvSDNNMilliseconds: hrvSDNNMilliseconds,
            restingHeartRate: restingHeartRate,
            sleepHours: sleepHours,
            sleepDeepHours: sleepDeepHours,
            sleepREMHours: sleepREMHours,
            bodyMassKilograms: bodyMassKilograms,
            respiratoryRate: respiratoryRate
        )
    }
}

/// The write payload — mirrors the phone's `HealthMetricUpsert` (snake_case
/// keys; synthesized `encodeIfPresent` omits the nil readiness/zone/
/// computed_at when a #109 keep-score pass must not stamp the row).
nonisolated struct HealthMetricInsert: Codable {
    let userId: UUID
    let date: String
    let readiness: Int?
    let zone: String?
    let computedAt: Date?
    let hrvSDNN: Double?
    let restingHR: Double?
    let sleepHours: Double?
    let sleepDeepHours: Double?
    let sleepREMHours: Double?
    let bodyMassKg: Double?
    let respiratoryRate: Double?

    init(metric: WatchHealthMetric, userID: UUID) {
        self.userId = userID
        self.date = metric.date
        self.readiness = metric.readiness
        self.zone = metric.zone
        self.computedAt = metric.computedAt
        self.hrvSDNN = metric.hrvSDNNMilliseconds
        self.restingHR = metric.restingHeartRate
        self.sleepHours = metric.sleepHours
        self.sleepDeepHours = metric.sleepDeepHours
        self.sleepREMHours = metric.sleepREMHours
        self.bodyMassKg = metric.bodyMassKilograms
        self.respiratoryRate = metric.respiratoryRate
    }

    enum CodingKeys: String, CodingKey {
        case date, readiness, zone
        case userId = "user_id"
        case computedAt = "computed_at"
        case hrvSDNN = "hrv_sdnn_ms"
        case restingHR = "resting_hr"
        case sleepHours = "sleep_hours"
        case sleepDeepHours = "sleep_deep_hours"
        case sleepREMHours = "sleep_rem_hours"
        case bodyMassKg = "body_mass_kg"
        case respiratoryRate = "resp_rate_bpm"
    }
}

extension Repo {
    static let healthWindowColumns = "date,readiness,zone,computed_at,hrv_sdnn_ms,resting_hr,sleep_hours,sleep_deep_hours,sleep_rem_hours,body_mass_kg,resp_rate_bpm"

    /// The whole candidate window for reconciliation (execute before any
    /// write so the precedence/insert-if-missing decisions see all rows).
    static func fetchHealthMetrics(limit: Int = WatchHealthReadWindow.candidateDays) async throws -> [HealthWindowRow] {
        try await SupabaseService
            .from("health_metrics")
            .select(healthWindowColumns)
            .order("date", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    /// Idempotent upsert keyed on `(user_id, date)`. `merge` = today's row
    /// (merge-duplicates resolution — biometrics/readiness may change);
    /// `false` = historical insert-if-missing (conflict-ignore, atomic
    /// against the key — a concurrent phone write leaves the row untouched).
    static func upsertHealthMetric(
        _ metric: WatchHealthMetric,
        userID: UUID,
        merge: Bool
    ) async throws {
        let insert = HealthMetricInsert(metric: metric, userID: userID)
        if merge {
            try await SupabaseService.from("health_metrics")
                .upsert(insert, onConflict: "user_id,date")
                .execute()
        } else {
            try await SupabaseService.from("health_metrics")
                .upsert(insert, onConflict: "user_id,date", ignoreDuplicates: true)
                .execute()
        }
    }
}
