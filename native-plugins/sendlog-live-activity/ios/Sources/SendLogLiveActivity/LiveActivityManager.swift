import ActivityKit
import Foundation
import UserNotifications

public extension Notification.Name {
    /// Posted after a lock-screen intent (or watch beat) mutates the workout
    /// activity, so the plugin can tell a live WebView to drain the queue.
    static let sendlogLiveActivityAction = Notification.Name("sendlog.liveActivityAction")
    /// Posted by sendlog-auth-bridge when a watch live-workout beat arrives
    /// (stretch: native lock-screen mirror while the WebView is suspended).
    static let sendlogLiveWorkoutBeat = Notification.Name("sendlog.liveWorkoutBeat")
}

/// Owns the two Live Activities (workout + Tindeq) and the pieces that must
/// work while the WebView is suspended: the lock-screen intent action queue,
/// the rest-over local notification, and the Tindeq segment stepper.
///
/// LiveActivityIntent.perform() runs in the APP process, so plain
/// UserDefaults.standard is shared between the intents, this manager and the
/// Capacitor plugin — no App Group needed.
@available(iOS 17.0, *)
public final class LiveActivityManager: @unchecked Sendable {
    public static let shared = LiveActivityManager()
    private init() {}

    private let queueKey = "sendmeter.pendingWorkoutActions"
    private let restNotificationId = "sendmeter.rest-over"
    private let lock = NSLock()

    // Last-known workout content state, so intents can transition natively.
    private var workoutState: WorkoutActivityAttributes.ContentState?

    // Tindeq schedule stepping.
    private struct Seg {
        let phase: String
        let side: String?
        let rep: Int
        let set: Int
        let startS: Double
        let durS: Double
    }
    private var tindeqSegs: [Seg] = []
    private var tindeqStartEpoch: Date = .distantPast
    private var tindeqPeakKg: Double?
    private var tindeqTimer: DispatchSourceTimer?

    // MARK: - Workout activity

    public func startWorkout(
        startedAt: Date, phase: String, phaseStartedAt: Date,
        restTargetS: Int?, boulderCount: Int
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Never stack: a relaunch/restart replaces any lingering activity.
        await endAllWorkoutActivities(dismissal: .immediate)
        let state = WorkoutActivityAttributes.ContentState(
            phase: phase, phaseStartedAt: phaseStartedAt,
            restTargetS: restTargetS, boulderCount: boulderCount
        )
        workoutState = state
        _ = try? Activity<WorkoutActivityAttributes>.request(
            attributes: WorkoutActivityAttributes(startedAt: startedAt),
            content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(12 * 3600))
        )
        scheduleRestNotification(for: state)
    }

    public func updateWorkout(
        phase: String, phaseStartedAt: Date, restTargetS: Int?, boulderCount: Int
    ) async {
        let state = WorkoutActivityAttributes.ContentState(
            phase: phase, phaseStartedAt: phaseStartedAt,
            restTargetS: restTargetS, boulderCount: boulderCount
        )
        workoutState = state
        for activity in Activity<WorkoutActivityAttributes>.activities {
            await activity.update(
                ActivityContent(state: state, staleDate: Date().addingTimeInterval(12 * 3600))
            )
        }
        scheduleRestNotification(for: state)
    }

    public func endWorkout(immediate: Bool) async {
        cancelRestNotification()
        workoutState = nil
        await endAllWorkoutActivities(dismissal: immediate ? .immediate : .default)
    }

    private func endAllWorkoutActivities(dismissal: ActivityUIDismissalPolicy) async {
        for activity in Activity<WorkoutActivityAttributes>.activities {
            var state = activity.content.state
            state.phase = "ended"
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: dismissal
            )
        }
    }

    // MARK: - Lock-screen intent actions

    /// Single entry point for BoulderIntent/StopIntent (and watch beats).
    /// Queues the action for the JS reducer AND applies it natively so the
    /// lock screen flips instantly even with the WebView suspended.
    public func handleAction(_ type: String, at date: Date) async {
        appendPendingAction(type: type, at: date)
        if var state = workoutState ?? Activity<WorkoutActivityAttributes>.activities.first?.content.state {
            switch type {
            case "beginBoulder" where state.phase != "climbing":
                state.phase = "climbing"
                state.phaseStartedAt = date
            case "endBoulder" where state.phase == "climbing":
                state.phase = "resting"
                state.phaseStartedAt = date
                state.boulderCount += 1
            default:
                break
            }
            await updateWorkout(
                phase: state.phase, phaseStartedAt: state.phaseStartedAt,
                restTargetS: state.restTargetS, boulderCount: state.boulderCount
            )
        }
        NotificationCenter.default.post(name: .sendlogLiveActivityAction, object: nil)
    }

    private func appendPendingAction(type: String, at date: Date) {
        lock.lock()
        defer { lock.unlock() }
        var queue = UserDefaults.standard.array(forKey: queueKey) as? [[String: String]] ?? []
        queue.append(["type": type, "at": ISO8601DateFormatter().string(from: date)])
        UserDefaults.standard.set(queue, forKey: queueKey)
    }

    /// Read + clear atomically — the JS reducer replays these (its phase
    /// guards make duplicates/no-ops safe).
    public func drainPendingActions() -> [[String: String]] {
        lock.lock()
        defer { lock.unlock() }
        let queue = UserDefaults.standard.array(forKey: queueKey) as? [[String: String]] ?? []
        UserDefaults.standard.removeObject(forKey: queueKey)
        return queue
    }

    // MARK: - Rest-over local notification

    public func requestNotificationPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    private func scheduleRestNotification(for state: WorkoutActivityAttributes.ContentState) {
        cancelRestNotification()
        guard state.phase == "resting", let target = state.restTargetS else { return }
        let fireIn = state.phaseStartedAt.addingTimeInterval(Double(target)).timeIntervalSinceNow
        guard fireIn > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Rest over"
        content.body = "Time to get back on the wall 🧗"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(
            identifier: restNotificationId,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: fireIn, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func cancelRestNotification() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [restNotificationId])
    }

    // MARK: - Tindeq activity

    public func startTindeq(
        title: String, targetKg: Double?, startEpochMs: Double,
        segments: [[String: Any]]
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        await endTindeq() // replace any lingering one
        tindeqSegs = segments.compactMap { raw in
            guard
                let phase = raw["p"] as? String,
                let rep = raw["rep"] as? Int,
                let set = raw["set"] as? Int,
                let startS = (raw["startS"] as? NSNumber)?.doubleValue,
                let durS = (raw["durS"] as? NSNumber)?.doubleValue
            else { return nil }
            return Seg(phase: phase, side: raw["s"] as? String, rep: rep, set: set, startS: startS, durS: durS)
        }
        guard !tindeqSegs.isEmpty else { return }
        tindeqStartEpoch = Date(timeIntervalSince1970: startEpochMs / 1000)
        tindeqPeakKg = nil
        _ = try? Activity<TindeqActivityAttributes>.request(
            attributes: TindeqActivityAttributes(title: title, targetKg: targetKg),
            content: ActivityContent(
                state: tindeqState(for: tindeqSegs[0]),
                staleDate: segEnd(tindeqSegs[0]).addingTimeInterval(30)
            )
        )
        armTindeqTimer()
    }

    public func updateTindeqStats(peakKg: Double) async {
        tindeqPeakKg = peakKg
        guard let seg = currentSeg() else { return }
        await pushTindeqState(seg)
    }

    public func endTindeq() async {
        tindeqTimer?.cancel()
        tindeqTimer = nil
        tindeqSegs = []
        for activity in Activity<TindeqActivityAttributes>.activities {
            await activity.end(
                ActivityContent(state: activity.content.state, staleDate: nil),
                dismissalPolicy: .immediate
            )
        }
    }

    private func segEnd(_ seg: Seg) -> Date {
        tindeqStartEpoch.addingTimeInterval(seg.startS + seg.durS)
    }

    private func currentSeg() -> Seg? {
        let elapsed = Date().timeIntervalSince(tindeqStartEpoch)
        return tindeqSegs.first { elapsed < $0.startS + $0.durS } ?? tindeqSegs.last
    }

    private func tindeqState(for seg: Seg) -> TindeqActivityAttributes.ContentState {
        TindeqActivityAttributes.ContentState(
            segPhase: seg.phase,
            side: seg.side,
            rep: seg.rep,
            set: seg.set,
            segStart: tindeqStartEpoch.addingTimeInterval(seg.startS),
            segEnd: segEnd(seg),
            peakKg: tindeqPeakKg
        )
    }

    private func pushTindeqState(_ seg: Seg) async {
        for activity in Activity<TindeqActivityAttributes>.activities {
            await activity.update(
                ActivityContent(state: tindeqState(for: seg), staleDate: segEnd(seg).addingTimeInterval(30))
            )
        }
    }

    /// One local update per segment boundary — well within budget. Keeps
    /// firing in background while the BLE link (bluetooth-central mode) keeps
    /// the process alive; if the process suspends anyway, the current
    /// segment's native countdown still reaches zero and the card goes stale.
    private func armTindeqTimer() {
        tindeqTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        tindeqTimer = timer
        scheduleNextTindeqFire(timer)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task {
                if let seg = self.currentSeg() {
                    await self.pushTindeqState(seg)
                }
                if let timer = self.tindeqTimer { self.scheduleNextTindeqFire(timer) }
            }
        }
        timer.resume()
    }

    private func scheduleNextTindeqFire(_ timer: DispatchSourceTimer) {
        let elapsed = Date().timeIntervalSince(tindeqStartEpoch)
        // next boundary strictly in the future
        let nextBoundary = tindeqSegs
            .map { $0.startS + $0.durS }
            .first { $0 > elapsed + 0.05 }
        guard let nextBoundary else { return }
        timer.schedule(deadline: .now() + (nextBoundary - elapsed) + 0.1)
    }
}
