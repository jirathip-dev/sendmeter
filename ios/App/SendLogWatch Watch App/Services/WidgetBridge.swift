import Foundation
import SendLogWatchCore
import WidgetKit

/// The watch app is the source of truth for its complications / Smart-Stack
/// widgets: widgets run in a separate process and can't hit the network, so we
/// push everything they need into the shared App Group snapshot (WidgetStore)
/// and ask WidgetKit to reload.
enum WidgetBridge {
    /// Refresh the glanceable status — readiness from the typed iPhone result
    /// + ACWR (computed here) — then reload. There is intentionally no
    /// watch-side `health_metrics` fetch: the readiness coordinator is the one
    /// request/result path, and this method only fills the independent ACWR.
    static func refreshStatus(readiness: ReadinessSnapshot? = nil) async {
        var snap = WidgetStore.load()
        if let readiness {
            // A successful result is authoritative, including a nil score
            // (the phone may have no HealthKit signal yet). An absent result
            // leaves the cached score visible while offline.
            snap.readiness = readiness.readiness
            snap.readinessZone = readiness.readiness == nil ? nil : readiness.zone
        }
        do {
            let ratio = try await computeACWR()
            snap.acwr = ratio
            snap.acwrRisk = StatusPresentation.acwrRiskBand(ratio)?.rawValue
        } catch {
            // Preserve the last known status while offline.
        }
        snap.updatedAt = Date().timeIntervalSince1970
        WidgetStore.save(snap)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Merge the live-workout fields and reload. Call on discrete changes
    /// (start / boulder toggle / end) — NOT every tick; the timer renders
    /// natively (Text(timerInterval:)) so per-second reloads aren't needed.
    static func updateLiveWorkout(
        active: Bool,
        boulders: Int = 0,
        climbing: Bool = false,
        phaseSince: Date? = nil,
        restTargetS: Int = 180
    ) {
        var snap = WidgetStore.load()
        snap.workoutActive = active
        snap.boulders = boulders
        snap.climbing = climbing
        snap.phaseSinceEpoch = phaseSince?.timeIntervalSince1970
        snap.restTargetS = restTargetS
        snap.updatedAt = Date().timeIntervalSince1970
        WidgetStore.save(snap)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // ACWR = acute (7-day EWMA) / chronic (28-day EWMA) of daily training
    // load, mean-seeded, over a 90-day window — same shape and same window
    // as the web app's metric (issue #189: the two used to disagree because
    // they used different windows/seeding). See ACWR.swift's KEEP-IN-SYNC
    // comment.
    private static func computeACWR() async throws -> Double? {
        let rows = try await Repo.fetchSessionLoads(sinceDays: 90)
        let series = dailyLoadSeries(rows: rows, days: 90)
        return ewmaAcwr(dailyLoads: series)
    }
}
