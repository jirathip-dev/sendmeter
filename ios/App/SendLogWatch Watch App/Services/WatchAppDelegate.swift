import Foundation
import SendLogWatchCore
import WatchKit

/// #802 AC3: WKApplicationRefreshBackgroundTask handling for the on-watch
/// readiness path. The system wakes the app in the preferred morning window
/// (`HealthSyncManager.scheduleAmbientRefreshIfNeeded`) and delivers the
/// refresh task here, which routes into the same single-flight health pass
/// as launch/foreground/observer triggers — the watch then recomputes the
/// morning score without the user opening the app. No detached timer is
/// part of the contract; the schedule is only an eligibility request.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            guard let refresh = task as? WKApplicationRefreshBackgroundTask else {
                task.setTaskCompleted()
                continue
            }
            // Blocker-2 fix: the pass is AWAITED — the background task may
            // only complete after the health pass (including its queued
            // follow-up) has finished, otherwise the runtime could suspend
            // the app mid-compute.
            Task { @MainActor in
                await HealthSyncManager.current?.runAwaitingBackgroundPass()
                refresh.setTaskCompleted()
            }
        }
    }
}
