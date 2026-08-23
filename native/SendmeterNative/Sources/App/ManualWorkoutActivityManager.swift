import ActivityKit
import Foundation
import SendmeterCore

public extension Notification.Name {
    /// Posted after a lock-screen intent changes the manual-workout activity,
    /// so WorkoutView can drain the pending action queue and mutate the
    /// authoritative `PhoneWorkoutEngine`.
    static let manualWorkoutActivityAction = Notification.Name(
        "sendmeter.native.manualWorkoutActivityAction"
    )
}

/// Lock-screen Live Activity for the Manual workout (#763) — the native
/// equivalent of the Capacitor `WorkoutLiveActivity` +
/// `LiveActivityManager.startWorkout/updateWorkout/endWorkout`.
///
/// The pure snapshot/action mapping lives in SendmeterCore
/// (`ManualWorkoutActivityContent`); this manager is the thin ActivityKit
/// adapter. It starts on workout begin, pushes ONLY on state transitions
/// (boulder drop-off, rest re-arm, rest-target change, end) — the lock screen
/// renders timers natively from the pushed timestamps, never per-tick.
///
/// Lock-screen intents run in the APP process and use this shared instance
/// so the card flips natively. The same action is also queued in
/// `UserDefaults.standard` for WorkoutView to replay into the engine, exactly
/// like the web's `drainPendingActions` contract; the queue survives a
/// process relaunch and is drained/discarded on the next WorkoutView appear.
///
/// Live Activities do not run in the simulator's gallery — device-only to
/// verify; every failure here is swallowed so the workout itself is never
/// affected.
@MainActor
public final class ManualWorkoutActivityManager {
    public static let shared = ManualWorkoutActivityManager()

    private static let pendingActionsKey = "sendmeter.native.manual-workout.pending-actions"

    private let defaults: UserDefaults
    private var activity: Activity<ManualWorkoutActivityAttributes>?
    private var lastState: ManualWorkoutActivityAttributes.ContentState?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isActive: Bool { activity != nil }

    /// Start a lock-screen activity mirroring this Manual workout. No-op when
    /// one is already active or Live Activities are unavailable.
    public func start(engine: PhoneWorkoutEngine, restTarget: Int) {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let snapshot = ManualWorkoutActivitySnapshot(engine: engine, restTarget: restTarget)
        let state = makeContentState(snapshot)
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(12 * 3600))
        do {
            activity = try Activity.request(
                attributes: ManualWorkoutActivityAttributes(startedAt: engine.draft.startedAt),
                content: content,
                pushType: nil
            )
            lastState = state
        } catch {
            activity = nil
            lastState = nil
        }
    }

    /// Keep the card in sync with the LIVE engine. Called on every structural
    /// transition; a no-op when the wire state is unchanged (e.g. an RPE
    /// slider move).
    public func refresh(engine: PhoneWorkoutEngine, restTarget: Int) {
        guard activity != nil else { return }
        let snapshot = ManualWorkoutActivitySnapshot(engine: engine, restTarget: restTarget)
        let state = makeContentState(snapshot)
        guard state != lastState else { return }
        lastState = state
        push(state)
    }

    public func sync(engine: PhoneWorkoutEngine?, restTarget: Int) {
        guard let engine else {
            end(immediate: true)
            return
        }
        if activity == nil {
            start(engine: engine, restTarget: restTarget)
        } else {
            refresh(engine: engine, restTarget: restTarget)
        }
    }

    /// Take the activity down. `immediate` for finish/cancel; a lingering
    /// dismissal would show a stale card for the system's default window.
    public func end(immediate: Bool = true) {
        lastState = nil
        guard let activity else { return }
        self.activity = nil
        Task {
            await activity.end(
                nil,
                dismissalPolicy: immediate ? .immediate : .default
            )
        }
    }

    /// Single entry point for BoulderIntent/StopIntent. Applies the transition
    /// to the card natively and queues it for the engine replay.
    public func handleAction(_ action: ManualWorkoutActivityAction, at date: Date = Date()) {
        appendPendingEvent(ManualWorkoutActivityEvent(action: action, at: date))
        let currentState = lastState
            ?? activity?.content.state
            ?? Activity<ManualWorkoutActivityAttributes>.activities.first?.content.state
        if let currentState {
            let snapshot = ManualWorkoutActivitySnapshot(
                phase: currentState.phase == "climbing" ? .climbing : .resting,
                phaseStartedAt: currentState.phaseStartedAt,
                restTargetSeconds: currentState.restTargetS ?? ManualWorkoutRest.defaultRestTarget,
                boulderCount: currentState.boulderCount
            )
            let updatedSnapshot = snapshot.applying(
                ManualWorkoutActivityEvent(action: action, at: date)
            )
            let updatedState = makeContentState(updatedSnapshot)
            if updatedState != currentState {
                lastState = updatedState
                push(updatedState)
            }
        }
        NotificationCenter.default.post(name: .manualWorkoutActivityAction, object: nil)
    }

    /// Read + clear the queued lock-screen actions atomically. WorkoutView
    /// replays these into `PhoneWorkoutEngine`; duplicates are rejected by
    /// the engine's existing guards.
    public func drainPendingEvents() -> [ManualWorkoutActivityEvent] {
        let data = defaults.array(forKey: Self.pendingActionsKey) as? [Data] ?? []
        defaults.removeObject(forKey: Self.pendingActionsKey)
        return data.compactMap { try? JSONDecoder().decode(ManualWorkoutActivityEvent.self, from: $0) }
    }

    public func discardPendingEvents() {
        defaults.removeObject(forKey: Self.pendingActionsKey)
    }

    /// #763 review F7-style orphan sweep: reconcile any activity that survived
    /// a force-quit or jetsam. Called on launch/foreground when no Manual
    /// workout is in progress.
    public func reconcileOrphans() {
        guard !isActive else { return }
        let activities = Activity<ManualWorkoutActivityAttributes>.activities
        guard !activities.isEmpty else { return }
        lastState = nil
        Task {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func appendPendingEvent(_ event: ManualWorkoutActivityEvent) {
        guard let data = try? JSONEncoder().encode(event) else { return }
        var events = defaults.array(forKey: Self.pendingActionsKey) as? [Data] ?? []
        events.append(data)
        defaults.set(events, forKey: Self.pendingActionsKey)
    }

    private func push(_ state: ManualWorkoutActivityAttributes.ContentState) {
        guard let activity else { return }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(12 * 3600))
        Task {
            await activity.update(content)
        }
    }

    private func makeContentState(
        _ snapshot: ManualWorkoutActivitySnapshot
    ) -> ManualWorkoutActivityAttributes.ContentState {
        ManualWorkoutActivityAttributes.ContentState(
            phase: snapshot.phase.rawValue,
            phaseStartedAt: snapshot.phaseStartedAt,
            restTargetS: snapshot.restTargetSeconds,
            boulderCount: snapshot.boulderCount
        )
    }
}
