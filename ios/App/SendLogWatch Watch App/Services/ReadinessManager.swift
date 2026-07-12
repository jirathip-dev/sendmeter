import Foundation
import Observation

/// Orchestrates the daily readiness computation: HealthKit inputs → watch-side
/// ACWR from own sessions → RecoveryEngine → local cache → idempotent upsert.
/// Health rows are recomputed on every refresh, so no offline queue is needed:
/// the last few days are kept in UserDefaults and re-upserted each time, which
/// self-heals days the watch spent offline.
@Observable
final class ReadinessManager {
    var result: ReadinessResult?
    var bodyMassKg: Double?
    var loading = false
    var errorMsg: String?

    private let provider: HealthMetricsProviding
    private let t: RecoveryTunables
    private static let cacheKey = "healthMetrics.recent"

    init(tunables: RecoveryTunables = .default) {
        self.t = tunables
        #if targetEnvironment(simulator)
        self.provider = FakeHealthMetricsProvider()
        #else
        self.provider = HealthKitMetricsProvider(tunables: tunables)
        #endif
    }

    @MainActor
    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        errorMsg = nil
        do {
            let inputs = try await provider.readToday()
            let acwr = try? await computeACWR()
            let res = RecoveryEngine.compute(inputs: inputs, acwr: acwr, t: t)
            result = res
            bodyMassKg = inputs.bodyMassKg

            let row = HealthMetricsUpsert(
                date: Date().localDateString,
                hrvSdnnMs: inputs.hrvSDNNms,
                restingHr: inputs.restingHR,
                sleepHours: inputs.sleepHours,
                sleepDeepHours: inputs.sleepDeepHours,
                sleepRemHours: inputs.sleepRemHours,
                bodyMassKg: inputs.bodyMassKg,
                respRateBpm: inputs.respRateBpm,
                readiness: res.score,
                zone: res.zone?.rawValue,
                computedAt: Date()
            )
            let recent = Self.updateCache(with: row, keep: t.recentDaysKept)
            try? await Repo.upsertHealthMetrics(recent)
        } catch {
            errorMsg = error.localizedDescription
        }
    }

    private static let ewmaLookbackDays = 90
    private static let ewmaLambdaAcute = 2.0 / (7.0 + 1.0)   // 7-day time constant
    private static let ewmaLambdaChronic = 2.0 / (28.0 + 1.0) // 28-day time constant

    /// Same math as the web's ewmaAcwr: exponentially-weighted acute:chronic
    /// ratio (Williams et al. 2016) rather than a plain rolling-average
    /// ratio — see metrics.ts for the full rationale. Both EWMAs are seeded
    /// with the 90-day mean load to shrink start-up bias.
    private func computeACWR() async throws -> Double? {
        let rows = try await Repo.fetchSessionLoads(sinceDays: Self.ewmaLookbackDays)
        var loadByDate: [String: Int] = [:]
        for r in rows { loadByDate[r.date, default: 0] += (r.load ?? 0) }

        let cal = Calendar.gregorianLocal
        var dailyLoads: [Double] = []
        for i in stride(from: Self.ewmaLookbackDays - 1, through: 0, by: -1) {
            let day = cal.date(byAdding: .day, value: -i, to: Date())!
            dailyLoads.append(Double(loadByDate[day.localDateString] ?? 0))
        }
        guard dailyLoads.contains(where: { $0 != 0 }) else { return nil }

        let seed = dailyLoads.reduce(0, +) / Double(dailyLoads.count)
        var emaAcute = seed
        var emaChronic = seed
        for load in dailyLoads {
            emaAcute = load * Self.ewmaLambdaAcute + emaAcute * (1 - Self.ewmaLambdaAcute)
            emaChronic = load * Self.ewmaLambdaChronic + emaChronic * (1 - Self.ewmaLambdaChronic)
        }
        return emaChronic > 0 ? emaAcute / emaChronic : nil
    }

    private static func updateCache(with row: HealthMetricsUpsert, keep: Int) -> [HealthMetricsUpsert] {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        var rows: [HealthMetricsUpsert] =
            (UserDefaults.standard.data(forKey: cacheKey)
                .flatMap { try? decoder.decode([HealthMetricsUpsert].self, from: $0) }) ?? []
        rows.removeAll { $0.date == row.date }
        rows.append(row)
        rows.sort { $0.date < $1.date }
        if rows.count > keep { rows.removeFirst(rows.count - keep) }
        if let data = try? encoder.encode(rows) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
        return rows
    }
}
