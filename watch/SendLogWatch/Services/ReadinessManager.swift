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
                bodyMassKg: inputs.bodyMassKg,
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

    /// Same math as the web's computeAcwr: acute 7d load sum vs 28d sum / 4.
    private func computeACWR() async throws -> Double? {
        let rows = try await Repo.fetchSessionLoads(sinceDays: 28)
        let cal = Calendar.gregorianLocal
        let acuteCutoff = cal.date(byAdding: .day, value: -6, to: Date())!.localDateString
        let acute = rows.filter { $0.date >= acuteCutoff }.reduce(0) { $0 + ($1.load ?? 0) }
        let chronic = Double(rows.reduce(0) { $0 + ($1.load ?? 0) }) / 4.0
        return chronic > 0 ? Double(acute) / chronic : nil
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
