import Foundation
import SendLogWatchCore
import WidgetKit

/// The watch app is the source of truth for its complications / Smart-Stack
/// widgets: widgets run in a separate process and can't hit the network, so we
/// push everything they need into the shared App Group snapshot (WidgetStore)
/// and ask WidgetKit to reload.
@MainActor
enum WidgetBridge {
    private static var refreshGate = ReadinessTaskGate()
    private static var refreshTask: Task<Void, Never>?
    private static var signedOut = false

    /// Re-enable writes after a real phone relay. A sign-out invalidates the
    /// prior task token; do not let a late task from the old account commit
    /// after this switch.
    static func activate() {
        if signedOut {
            refreshTask?.cancel()
            refreshTask = nil
            refreshGate.invalidate()
        }
        signedOut = false
    }

    /// Cancel/gate all async status work and remove the shared snapshot. The
    /// write guard also prevents a late workout/status callback from recreating
    /// stale account data until a new signed-in relay activates the bridge.
    static func invalidate() {
        signedOut = true
        refreshTask?.cancel()
        refreshTask = nil
        refreshGate.invalidate()
        WidgetStore.clear()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Refresh the glanceable status — readiness from the typed iPhone result
    /// + ACWR (computed here) — then reload. There is intentionally no
    /// watch-side `health_metrics` fetch: the readiness coordinator is the one
    /// request/result path, and this method only fills the independent ACWR.
    static func refreshStatus(readiness: ReadinessSnapshot? = nil) async {
        guard !signedOut else { return }

        refreshTask?.cancel()
        let owner = refreshGate.begin()
        let task = Task { @MainActor in
            await commitStatus(owner: owner, readiness: readiness)
        }
        refreshTask = task
        await task.value
        if refreshGate.isCurrent(owner) {
            refreshTask = nil
        }
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
        guard !signedOut else { return }
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

    private static func commitStatus(
        owner: ReadinessTaskGate.Token,
        readiness: ReadinessSnapshot?
    ) async {
        var didFetchACWR = false
        var ratio: Double?
        do {
            ratio = try await computeACWR()
            didFetchACWR = true
        } catch {
            // Preserve the last known ACWR while offline.
        }

        // Read only after every await. This fresh merge preserves live-workout
        // fields written while ACWR was in flight and is discarded entirely
        // when sign-out or a newer refresh took ownership.
        guard !Task.isCancelled, !signedOut, refreshGate.isCurrent(owner) else { return }
        var snap = WidgetStore.load()
        if let readiness {
            // A successful result is authoritative, including a nil score
            // (the phone may have no HealthKit signal yet). An absent result
            // leaves the cached score visible while offline.
            snap.readiness = readiness.readiness
            snap.readinessZone = readiness.readiness == nil ? nil : readiness.zone
        }
        if didFetchACWR {
            snap.acwr = ratio
            snap.acwrRisk = StatusPresentation.acwrRiskBand(ratio)?.rawValue
        }
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
