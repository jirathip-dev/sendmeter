import Foundation
import SendLogWatchCore
import WidgetKit

/// The watch app is the source of truth for its complications / Smart-Stack
/// widgets: widgets run in a separate process and can't hit the network, so we
/// push everything they need into the shared App Group snapshot (WidgetStore)
/// and ask WidgetKit to reload.
enum WidgetBridge {
    /// Refresh the glanceable status — readiness (from the iPhone's synced row)
    /// + ACWR (computed here) — then reload. Call after a readiness sync / on
    /// foreground.
    static func refreshStatus() async {
        var snap = WidgetStore.load()
        if let row = try? await Repo.fetchLatestHealthMetric() {
            snap.readiness = row.readiness
            snap.readinessZone = row.zone
        }
        if let ratio = try? await computeACWR() {
            snap.acwr = ratio
            snap.acwrRisk = ratio < 0.8 ? "low" : (ratio > 1.5 ? "high" : "optimal")
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
