import Foundation
import SendLogHealthCore
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

/// PostgREST RPC argument body for
/// `upsert_health_metrics_with_precedence` (#802). Keys are the function's
/// `p_*` parameter names. `p_*` optionals encode as null (Postgres NULL)
/// — a nil readiness/zone/computed_at is exactly the #109 keep-score merge.
nonisolated struct HealthPrecedenceRpcParams: Encodable {
    let pUserId: UUID
    let pDate: String
    let pHrvSDNNMs: Double?
    let pRestingHR: Double?
    let pSleepHours: Double?
    let pSleepDeepHours: Double?
    let pSleepREMHours: Double?
    let pBodyMassKg: Double?
    let pRespRateBpm: Double?
    let pReadiness: Int?
    let pZone: String?
    let pComputedAt: Date?
    let pWriter: String
    let pTimezone: String

    init(metric: WatchHealthMetric, userID: UUID, writer: String, timeZone: TimeZone) {
        self.pUserId = userID
        self.pDate = metric.date
        self.pHrvSDNNMs = metric.hrvSDNNMilliseconds
        self.pRestingHR = metric.restingHeartRate
        self.pSleepHours = metric.sleepHours
        self.pSleepDeepHours = metric.sleepDeepHours
        self.pSleepREMHours = metric.sleepREMHours
        self.pBodyMassKg = metric.bodyMassKilograms
        self.pRespRateBpm = metric.respiratoryRate
        self.pReadiness = metric.readiness
        self.pZone = metric.zone
        self.pComputedAt = metric.computedAt
        self.pWriter = writer
        self.pTimezone = timeZone.identifier
    }

    enum CodingKeys: String, CodingKey {
        case pUserId = "p_user_id"
        case pDate = "p_date"
        case pHrvSDNNMs = "p_hrv_sdnn_ms"
        case pRestingHR = "p_resting_hr"
        case pSleepHours = "p_sleep_hours"
        case pSleepDeepHours = "p_sleep_deep_hours"
        case pSleepREMHours = "p_sleep_rem_hours"
        case pBodyMassKg = "p_body_mass_kg"
        case pRespRateBpm = "p_resp_rate_bpm"
        case pReadiness = "p_readiness"
        case pZone = "p_zone"
        case pComputedAt = "p_computed_at"
        case pWriter = "p_writer"
        case pTimezone = "p_timezone"
    }
}

/// One returned row of the precedence RPC (#802): the decision plus the
/// canonical row that now owns the date (the retained server row when the
/// decision is `retained`, the just-written row when `written`).
nonisolated struct HealthPrecedenceRpcResult: Codable, Equatable, Sendable {
    var decision: String
    var date: String?
    var readiness: Int?
    var zone: String?
    var computedAt: Date?

    enum CodingKeys: String, CodingKey {
        case decision, date, readiness, zone
        case computedAt = "computed_at"
    }
}

enum HealthRepositoryError: Error {
    case emptyRpcResult
}

extension Repo {
    static let healthWindowColumns = "date,readiness,zone,computed_at,hrv_sdnn_ms,resting_hr,sleep_hours,sleep_deep_hours,sleep_rem_hours,body_mass_kg,resp_rate_bpm"

    /// The whole candidate window for reconciliation (execute before any
    /// write so the #801 insert-if-missing selection sees all rows).
    static func fetchHealthMetrics(limit: Int = WatchHealthReadWindow.candidateDays) async throws -> [HealthWindowRow] {
        try await SupabaseService
            .from("health_metrics")
            .select(healthWindowColumns)
            .order("date", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    /// The ONE write path (Atomic #802): the Postgres function decides the
    /// dual-source winner inside a single transaction against the live row
    /// (`written` / `retained` / `discarded`) and returns the canonical row.
    /// No client-side fetch-then-upsert can clobber a rival write.
    static func upsertHealthMetricWithPrecedence(
        _ metric: WatchHealthMetric,
        userID: UUID,
        writer: HealthMetricWriter,
        timeZone: TimeZone
    ) async throws -> HealthPrecedenceRpcResult {
        let params = HealthPrecedenceRpcParams(
            metric: metric,
            userID: userID,
            writer: writer.rawValue,
            timeZone: timeZone
        )
        let rows: [HealthPrecedenceRpcResult] = try await SupabaseService
            .rpc("upsert_health_metrics_with_precedence", params: params)
            .execute()
            .value
        guard let row = rows.first else {
            throw HealthRepositoryError.emptyRpcResult
        }
        return row
    }
}
