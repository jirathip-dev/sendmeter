import Foundation
import Observation

/// Readiness zone for display (mirrors the values the iPhone writes to
/// health_metrics.zone). Kept watch-local so the watch needn't depend on the
/// health-core package — it only reads two fields back.
enum ReadinessZone: String {
    case recover, maintain, push
}

struct ReadinessDisplay {
    let score: Int?
    let zone: ReadinessZone?
    let driver: String
}

/// The iPhone app now owns health ingestion and readiness computation (it can
/// see third-party wearables in the merged HealthKit store; the watch's local
/// store can't). The watch just reads the latest computed score back from
/// Supabase for display — no HealthKit reads, no compute, no upsert here.
@Observable
final class ReadinessManager {
    var result: ReadinessDisplay?
    var loading = false
    var errorMsg: String?

    @MainActor
    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        errorMsg = nil
        do {
            if let row = try await Repo.fetchLatestHealthMetric(), row.readiness != nil {
                result = ReadinessDisplay(
                    score: row.readiness,
                    zone: row.zone.flatMap(ReadinessZone.init(rawValue:)),
                    driver: "Synced \(row.date)"
                )
            } else {
                result = ReadinessDisplay(
                    score: nil, zone: nil,
                    driver: "Open the iPhone app to sync Health"
                )
            }
        } catch {
            errorMsg = error.localizedDescription
        }
    }
}
