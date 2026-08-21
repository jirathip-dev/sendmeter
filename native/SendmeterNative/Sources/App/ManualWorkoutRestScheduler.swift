import SendmeterCore
import SwiftUI
import UserNotifications

/// Owns the Manual workout rest deadline independently of the fullscreen
/// presentation. The workout view can be minimized or recreated without
/// losing the alert timer or its once-per-rest feedback decision.
@MainActor
public final class ManualWorkoutRestScheduler {
    private static let notificationIdentifierPrefix = "sendmeter.native.manual-workout.rest-over"

    private let notificationCenter = UNUserNotificationCenter.current()
    private var currentSchedule: ManualWorkoutRest.Schedule?
    private var deadlineTask: Task<Void, Never>?
    private var sceneIsActive = true
    private var backgroundEnteredAt: Date?
    private var notificationLedger = ManualWorkoutNotificationLedger()
    private var lastFeedbackKey: String?
    private var notificationAuthorization: UNAuthorizationStatus?

    public init() {
        cancelNotification()
    }

    deinit {
        let identifiers = notificationLedger.ownedIdentifiers
        guard !identifiers.isEmpty else { return }
        notificationCenter.removePendingNotificationRequests(
            withIdentifiers: Array(identifiers)
        )
        notificationCenter.removeDeliveredNotifications(
            withIdentifiers: Array(identifiers)
        )
    }

    public func update(engine: PhoneWorkoutEngine?, restTarget: Int) {
        guard let engine, engine.attemptStartedAt == nil else {
            stop()
            return
        }

        let schedule = ManualWorkoutRest.schedule(
            workoutStartedAt: engine.draft.startedAt,
            attempts: engine.draft.attempts,
            targetSeconds: restTarget
        )
        let changed = currentSchedule?.key != schedule.key
            || currentSchedule?.deadline != schedule.deadline

        if changed {
            deadlineTask?.cancel()
            deadlineTask = nil
            cancelNotification()
            currentSchedule = schedule
            backgroundEnteredAt = nil
        } else {
            currentSchedule = schedule
        }

        scheduleNotificationIfNeeded(for: schedule)
        armDeadline(for: schedule)
        evaluate(now: Date())
    }

    public func stop() {
        deadlineTask?.cancel()
        deadlineTask = nil
        currentSchedule = nil
        backgroundEnteredAt = nil
        lastFeedbackKey = nil
        cancelNotification()
    }

    public func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            sceneIsActive = true
            scheduleNotificationIfNeeded(for: currentSchedule)
            evaluate(now: Date())
            if let currentSchedule {
                armDeadline(for: currentSchedule)
            }
        case .background:
            sceneIsActive = false
            if backgroundEnteredAt == nil {
                backgroundEnteredAt = Date()
            }
            scheduleNotificationIfNeeded(for: currentSchedule)
        case .inactive:
            sceneIsActive = false
        @unknown default:
            sceneIsActive = false
        }
    }

    /// Called only from the user-initiated Start button. Minimize/resume does
    /// not ask again; its original local notification remains owned here.
    public func requestNotificationPermissionIfNeeded() async {
        let status = await authorizationStatus()
        notificationAuthorization = status

        switch status {
        case .notDetermined:
            do {
                _ = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
            } catch {
                return
            }
            notificationAuthorization = await authorizationStatus()
            if notificationAuthorization == .denied {
                cancelNotification()
            } else {
                scheduleNotificationIfNeeded(for: currentSchedule)
            }
        case .denied:
            cancelNotification()
        case .authorized, .provisional, .ephemeral:
            scheduleNotificationIfNeeded(for: currentSchedule)
        @unknown default:
            cancelNotification()
        }
    }

    private func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            notificationCenter.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    private func scheduleNotificationIfNeeded(for schedule: ManualWorkoutRest.Schedule?) {
        guard let schedule,
              notificationAuthorization != .denied,
              notificationLedger.scheduledKey != schedule.key,
              let delay = ManualWorkoutRest.notificationDelay(
                  now: Date(),
                  deadline: schedule.deadline
              )
        else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Rest over"
        content.body = "Time to get back on the wall"
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let token = UUID()
        let notificationIdentifier = ManualWorkoutNotificationLedger.Request(
            identifier: "\(Self.notificationIdentifierPrefix).\(token.uuidString)",
            scheduleKey: schedule.key,
            token: token
        )
        let request = UNNotificationRequest(
            identifier: notificationIdentifier.identifier,
            content: content,
            trigger: trigger
        )
        guard notificationLedger.submit(notificationIdentifier) else { return }
        notificationCenter.add(request) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                switch self.notificationLedger.complete(
                    notificationIdentifier,
                    succeeded: error == nil
                ) {
                case .stale:
                    self.removeNotification(identifier: notificationIdentifier.identifier)
                case .scheduled:
                    guard self.currentSchedule?.key == notificationIdentifier.scheduleKey else {
                        self.removeNotification(identifier: notificationIdentifier.identifier)
                        return
                    }
                case .failed:
                    self.removeNotification(identifier: notificationIdentifier.identifier)
                    self.scheduleNotificationIfNeeded(for: self.currentSchedule)
                }
            }
        }
    }

    private func cancelNotification() {
        let identifiers = notificationLedger.cancelAll()
        guard !identifiers.isEmpty else { return }
        notificationCenter.removePendingNotificationRequests(
            withIdentifiers: Array(identifiers)
        )
        notificationCenter.removeDeliveredNotifications(
            withIdentifiers: Array(identifiers)
        )
    }

    private func removeNotification(identifier: String) {
        notificationCenter.removePendingNotificationRequests(
            withIdentifiers: [identifier]
        )
        notificationCenter.removeDeliveredNotifications(
            withIdentifiers: [identifier]
        )
    }

    private func armDeadline(for schedule: ManualWorkoutRest.Schedule) {
        deadlineTask?.cancel()
        let delay = schedule.deadline.timeIntervalSinceNow
        guard delay > 0 else {
            deadlineReached(key: schedule.key)
            return
        }

        deadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(max(1, delay * 1_000_000_000))
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.deadlineReached(key: schedule.key)
        }
    }

    private func deadlineReached(key: String) {
        guard currentSchedule?.key == key else { return }
        evaluate(now: Date())
    }

    private func evaluate(now: Date) {
        guard let schedule = currentSchedule else { return }
        let passedWhileBackground: Bool
        if let backgroundEnteredAt {
            passedWhileBackground = backgroundEnteredAt <= schedule.deadline
                && now >= schedule.deadline
        } else {
            passedWhileBackground = false
        }

        let decision = ManualWorkoutRest.feedbackDecision(
            now: now,
            schedule: schedule,
            sceneIsActive: sceneIsActive,
            deadlinePassedWhileBackground: passedWhileBackground,
            notificationWasScheduled: notificationLedger.scheduledKey == schedule.key,
            lastFeedbackKey: lastFeedbackKey
        )
        switch decision {
        case .none:
            break
        case .playForeground, .suppressForBackgroundNotification:
            lastFeedbackKey = schedule.key
            cancelNotification()
            if decision == .playForeground {
                ManualWorkoutRestAlert.play()
            }
        }
    }
}
