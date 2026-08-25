import BackgroundTasks
import Foundation
import SendmeterCore

/// BGTaskScheduler wiring for the native target.
///
/// Only the scheduler and task lifecycle live here. The actual work is the
/// testable `BackgroundSyncEngine` body driven by `AppModel.runBackgroundSync()`,
/// so simulator tests can prove the drain/reconcile/account-guard ordering
/// without depending on the OS running a BGAppRefreshTask.
public enum BackgroundSyncService {
    static let taskIdentifier = "com.jirathip.sendlog.background-refresh"

    private static let lock = NSLock()
    private static var lastSubmittedAt: Date?

    /// Registers the launch handler. Must run before the app finishes
    /// launching; `SendmeterNativeApp.init` calls it once.
    public static func register(model: AppModel) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let session = BackgroundSyncSession()
            refreshTask.expirationHandler = {
                session.expire(task: refreshTask)
            }
            session.start(model: model, task: refreshTask)
        }
    }

    /// Submits the next refresh. Idempotent within one minimum interval so a
    /// background entry plus the completed-task re-arm cannot queue duplicates
    /// while the first request is still pending.
    public static func schedule(
        minimumInterval: TimeInterval = 15 * 60
    ) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if let lastSubmittedAt,
           now.timeIntervalSince(lastSubmittedAt) < minimumInterval {
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: minimumInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
            lastSubmittedAt = now
        } catch {
            lastSubmittedAt = nil
        }
    }

    /// The scheduler has started the pending request, so the next submission
    /// is a fresh request rather than a duplicate. Called from the task handler
    /// before the work starts; completion and expiration re-arm from the same
    /// path.
    static func markTaskStarted() {
        lock.lock()
        defer { lock.unlock() }
        lastSubmittedAt = nil
    }
}

private final class BackgroundSyncSession: @unchecked Sendable {
    private enum State {
        case running
        case completed
        case expired
    }

    private let lock = NSLock()
    private var state = State.running
    private var workTask: Task<Void, Never>?

    func start(model: AppModel, task: BGAppRefreshTask) {
        lock.lock()
        defer { lock.unlock() }
        BackgroundSyncService.markTaskStarted()
        let work = Task { @MainActor in
            let outcome = await model.runBackgroundSync()
            var success = false
            if case .completed = outcome {
                success = true
            }
            self.finish(task: task, success: success)
        }
        workTask = work
    }

    func expire(task: BGAppRefreshTask) {
        lock.lock()
        guard state == .running else {
            lock.unlock()
            return
        }
        state = .expired
        let work = workTask
        lock.unlock()

        work?.cancel()
        task.setTaskCompleted(success: false)
        BackgroundSyncService.schedule()
    }

    private func finish(task: BGAppRefreshTask, success: Bool) {
        lock.lock()
        guard state == .running else {
            lock.unlock()
            return
        }
        state = .completed
        workTask = nil
        lock.unlock()

        BackgroundSyncService.schedule()
        task.setTaskCompleted(success: success)
    }
}
