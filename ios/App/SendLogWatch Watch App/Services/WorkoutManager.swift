import CoreMotion
import Foundation
import HealthKit
import Observation
import SendLogWatchCore
import WatchConnectivity
import WatchKit

/// Runs an HKWorkoutSession (climbing, indoor) with live HR from
/// HKLiveWorkoutBuilder, fused at 1 Hz with CMAltimeter relative altitude and
/// a 2 s RMS of CMMotionManager userAcceleration into the AttemptDetector.
@Observable
final class WorkoutManager: NSObject {
    var isRunning = false
    var heartRate: Double?
    var activeKcal: Double = 0
    var elapsed: TimeInterval = 0
    /// Non-negative height above the current attempt's local resting floor.
    var relativeAltitude: Double = 0
    var liveAttempts = 0
    /// True while either an automatic or manual boulder is visibly open.
    var manualClimbing = false
    /// When the current visible boulder started (nil while resting).
    var climbingSince: Date?
    /// When the current rest began — workout start, or the last boulder's end.
    /// The rest countdown starts automatically (phone-workout logic).
    var restStartedAt: Date?
    /// Rest countdown target in seconds — persisted, same chips as the phone.
    var restTargetS: Int = WorkoutManager.loadRestTarget() {
        didSet {
            UserDefaults.standard.set(restTargetS, forKey: "restTargetS")
            pushBeat() // phone mirror should see the new target promptly
            scheduleRestAlarm() // a no-op while climbing (guards on restStartedAt)
        }
    }
    var errorMsg: String?
    /// Training phase captured at workout START, so the save doesn't need a
    /// network round-trip on the critical path (it builds the bundle from this).
    var cachedPhase = "capacity"

    // MARK: Save path (#476: hoisted out of WorkoutLiveView)
    //
    // A save started by `endAndSave()` used to run as a bare `Task` closure
    // over WorkoutLiveView's @State — a struct's captured state, not tied to
    // the live view identity. If the view was torn down mid-save (a
    // complication deep link, or RootView swapping the whole NavigationStack
    // on a signedOut auth relay), the in-flight save kept running but its
    // completion wrote into state nobody could read any more: `failedBundle`
    // (the #287 in-memory last copy of a workout whose disk write AND direct
    // upload both failed) was lost right when it mattered most. Living on the
    // App-scoped manager instead means a freshly (re)created WorkoutLiveView
    // reads the real outcome.
    var ending = false
    /// Brief "Saved ✓" confirmation after auto-save-on-stop.
    var justSaved = false
    /// Whether the just-saved bundle is still sitting in the offline queue
    /// (issue #189) — checked right before showing `justSaved`, so
    /// `WidgetBridge.refreshStatus()`'s own network round trip below gives
    /// `drain()` a real chance to finish uploading first when signed in.
    /// Signed-out stays queued deterministically (`drain()` no-ops
    /// immediately), so this reliably distinguishes "still uploading" from
    /// "stuck until sign-in" without touching `drain()`/`shouldDrain`.
    var stillQueued = false
    /// Kept in memory after both persistence and direct upload fail (#287),
    /// so Retry can replay the same idempotent bundle instead of pretending
    /// the workout was saved. **Deliberately NOT reset by `start()`**
    /// (review finding F1): discarding it there would silently throw away
    /// the last copy of an unsaved workout a second time. It also must
    /// never gate the UI — `WorkoutLiveView` surfaces it as a banner inside
    /// `startContent`, not as a competing exclusive screen, so a failed save
    /// from workout N can never block starting workout N+1. See
    /// `WorkoutScreenSelection` (SendLogWatchCore) for the render-order
    /// rules this depends on.
    var failedBundle: WorkoutSaveBundle?

    private static func loadRestTarget() -> Int {
        let v = UserDefaults.standard.integer(forKey: "restTargetS")
        return [60, 120, 180, 300].contains(v) ? v : 180
    }

    private let tunables: Tunables
    private var detector: AttemptDetector
    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private let altimeter = CMAltimeter()
    private let motion = CMMotionManager()
    private var accelBuffer: [(t: TimeInterval, mag: Double)] = []
    // Not `private`: SendLogWatchTests (@testable import) exercises the
    // deinit-invalidates-the-timer guarantee directly against these two.
    var fusionTimer: Timer?
    /// Guards `start()` against a double tap reaching HealthKit setup twice,
    /// and stamps the cached-phase fetch so a stale one (from a workout that
    /// already ended) can't overwrite a later workout's `cachedPhase` — see
    /// `WorkoutStartGuard`'s doc comment for why hoisting makes this real.
    private var startGuard = WorkoutStartGuard()
    /// Test-only observable (SendLogWatchTests, @testable import): how many
    /// `start()` calls the guard has accepted so far. A real HealthKit setup
    /// attempt/timer isn't reliably observable from this test host (no HK
    /// entitlement), but this directly reflects whether the guard let a call
    /// through — a concurrent double-tap must still only ever accept one.
    var acceptedStartCount: Int { startGuard.generation }
    // Not `private`: SendLogWatchTests drives `performFusionTick(now:)`
    // directly with a controlled `startDate`/`now` — HealthKit delivery
    // timing (and thus real HR staleness) isn't controllable from a test
    // host with no HealthKit entitlement, so this is the seam (#477).
    var startDate: Date?
    private var rawRelativeAltitude: Double = 0
    // Not `private`: same reason as `startDate` above — tests assert on the
    // persisted rows directly after age expiry (#477) rather than trusting a
    // comment that the same value feeds them.
    var rawTrace: [[Double?]] = []
    /// The most recently constructed fusion-tick sample, purely for test
    /// observability (#477) — production code never reads this back.
    var lastMotionSample: MotionSample?
    // Generated at start so the live_workouts heartbeat and the final
    // climb_workouts row share one id (web correlation).
    private var workoutId = UUID()
    private var liveSync: LiveWorkoutSync?
    private var fusionTick = 0
    /// Sample-timestamped, monotonic HR — see `HeartRateTimeline`'s doc
    /// comment (#477). Replaces the old bare `didCollectDataOf` → `heartRate`
    /// assignment, which held whatever arrived last with no age and no
    /// protection against an out-of-order callback moving it backwards.
    private var hrTimeline = HeartRateTimeline()
    // MARK: Partial-flush ordering (#477)
    //
    // `flushPartial()` used to fire an unconstrained `Task.detached` every
    // ~2 min with no in-flight gate and no sequence number, and `end()`
    // neither awaited nor cancelled it. A slow partial upsert could then
    // land AFTER the final row and overwrite it with provisional data
    // (truncated `raw`, smaller counts, a provisional `ended_at`) — the
    // CLAUDE.md #295/#296 class of bug: an async closure carrying old state
    // past an await, still allowed to decide final persisted state.
    // Cancelling the detached Task doesn't fix this: once its request is on
    // the wire, cancellation can't stop the server committing it. `end()`
    // must AWAIT whatever is already in flight instead.
    /// Coalesces flush requests that arrive while one is already running —
    /// a skipped flush must run again with the LATEST snapshot afterward,
    /// not be silently dropped (that dropped window is what lost data in
    /// #470).
    private var partialFlushDrain = CoalescingDrain()
    /// The network call currently in flight, if any — `end()` awaits this.
    private var partialFlushTask: Task<Void, Never>?
    /// Set by `end()` before it awaits the in-flight task, so the
    /// completion handler below treats a coalesced rerun request as
    /// cancelled rather than starting one more partial upsert after the
    /// workout has already begun finishing (a rerun that started after would
    /// race the final row the same way the un-awaited detached Task used to).
    private var partialFlushSuspended = false
    /// Not `private`: the production default is `Repo.flushPartialWorkout`
    /// (the one file this fix must not touch, #475 owns it) — tests inject a
    /// deferred closure to prove `end()` actually waits for network
    /// completion, not just a generation-counter compare, since the network
    /// itself isn't testable here.
    var partialUploader: (ClimbWorkoutPartialUpsert) async -> Void = { partial in
        try? await Repo.flushPartialWorkout(partial)
    }
    /// Double haptic when the rest countdown hits zero (#476 F5: hoisted out
    /// of WorkoutLiveView, same reasoning as the save path — a rest alarm
    /// scheduled while the view was on screen used to be silently cancelled
    /// by any navigation away from it (`.onDisappear`), which was harmless
    /// pre-hoist (the whole workout died with the view) but became a real
    /// dropped-haptic regression once the workout started surviving
    /// navigation. Scheduling it here, tied to `restStartedAt` transitions
    /// directly, means it survives navigation exactly like everything else.
    private var restAlarmTask: Task<Void, Never>?

    init(tunables: Tunables = .default) {
        self.tunables = tunables
        self.detector = AttemptDetector(tunables: tunables)
        super.init()
    }

    /// `end()` already invalidates the fusion timer, but that's not the only
    /// way this object goes away — invalidate here too, or a path that skips
    /// `end()` (deallocation without an explicit stop) leaves the timer
    /// registered on the run loop, which retains it and keeps firing forever
    /// into a `[weak self]` that's already nil.
    deinit {
        fusionTimer?.invalidate()
    }

    func requestAuthorization() async throws {
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        let read: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
        ]
        try await healthStore.requestAuthorization(toShare: share, read: read)
    }

    @MainActor
    func start() async {
        // Rejects a second concurrent call synchronously, before the first
        // `await` below — a double tap on Start otherwise reaches
        // `requestAuthorization`/`startFusion` twice, and the second
        // `startFusion` overwrites `fusionTimer` without invalidating the
        // first, orphaning a timer the run loop keeps firing.
        guard let generation = startGuard.begin() else { return }
        defer { startGuard.finish() }
        // Re-review R2: refuse to start over an already-running workout too.
        // The guard above only rejects a CONCURRENT second call — a later,
        // sequential call (e.g. some future caller reachable while
        // `isRunning` is already true) would otherwise reach the reset block
        // below and nil out `session`/`builder`/`startDate` for the
        // workout that's actually live, then possibly throw inside
        // `requestAuthorization()` — orphaning that HKWorkoutSession with no
        // handle left to end it: `isRunning` stays true, the view keeps
        // rendering `.live`, and `end()`'s `guard let session ... else {
        // return nil }` silently does nothing. That's the exact shape of
        // the bug #476 exists to fix.
        guard !isRunning else { return }

        errorMsg = nil
        // Review finding F1: this manager now outlives any single workout,
        // so the previous workout's save-path fields must be explicitly
        // decided here, not left to carry into the new one's render.
        // `ending`/`justSaved`/`stillQueued` are per-save transients with
        // nothing to lose — clear them. `failedBundle` is deliberately left
        // untouched; see its doc comment above for why.
        ending = false
        justSaved = false
        stillQueued = false
        // Review finding F7: defensive — every path that sets these also
        // runs `end()`, which nils them, so this isn't reachable today, but
        // it closes the same "long-lived manager" exposure as the fields
        // above at no cost.
        session = nil
        builder = nil
        startDate = nil
        liveSync = nil
        cancelRestAlarm() // review finding F5: no stale alarm from a previous rest
        // Warm the phase in the background so save-on-stop needs no network.
        // Stamped with this start's generation: once hoisted, this manager
        // outlives any single workout, so a slow fetch from a PREVIOUS start
        // must not land on the workout that's running by the time it resolves.
        Task {
            let phase = (try? await Repo.fetchCurrentPhase()) ?? "capacity"
            guard self.startGuard.isCurrent(generation) else { return }
            self.cachedPhase = phase
        }
        detector = AttemptDetector(tunables: tunables)
        rawTrace = []
        accelBuffer = []
        heartRate = nil
        hrTimeline = HeartRateTimeline()
        lastMotionSample = nil
        activeKcal = 0
        elapsed = 0
        relativeAltitude = 0
        rawRelativeAltitude = 0
        liveAttempts = 0
        manualClimbing = false
        climbingSince = nil
        restStartedAt = nil
        fusionTick = 0
        workoutId = UUID()
        // #477: a previous workout's partial-flush bookkeeping must not
        // carry into this one — a leftover `partialFlushSuspended = true`
        // would silently disable durable flushing for the entire next
        // workout.
        partialFlushDrain = CoalescingDrain()
        partialFlushTask = nil
        partialFlushSuspended = false

        do {
            try await requestAuthorization()

            let config = HKWorkoutConfiguration()
            config.activityType = .climbing
            config.locationType = .indoor

            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self

            let start = Date()
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)

            self.session = session
            self.builder = builder
            self.startDate = start
            self.liveSync = LiveWorkoutSync(workoutId: workoutId, startedAt: start)
            // Phone-workout logic: a workout begins RESTING — the countdown
            // runs until the first boulder starts.
            self.restStartedAt = start
            scheduleRestAlarm()

            startAltimeter()
            startMotion()
            startFusion()
            isRunning = true
            refitRPEModelIfStale()
            // Surface the live workout in the Smart Stack / complications.
            WidgetBridge.updateLiveWorkout(
                active: true, boulders: 0, climbing: false,
                phaseSince: start, restTargetS: restTargetS
            )
        } catch {
            errorMsg = error.localizedDescription
        }
    }

    /// Toggle the visible boulder attempt (Boulder ⇄ Stop). A new attempt is
    /// manual; stopping an auto attempt preserves its auto provenance. Stop
    /// drops into the rest countdown; both transitions beat immediately so
    /// the phone mirror flips without waiting for the 5 s heartbeat.
    @MainActor
    func toggleManualAttempt() {
        let now = Date()
        if detector.snapshot.isClimbing {
            detector.endCurrentAttempt(at: now)
            climbingSince = nil
            restStartedAt = now
            scheduleRestAlarm()
        } else {
            detector.beginManualAttempt(at: now)
            climbingSince = now
            restStartedAt = nil
            cancelRestAlarm()
        }
        manualClimbing = detector.snapshot.isClimbing
        relativeAltitude = detector.snapshot.localHeightM
        liveAttempts = detector.liveAttemptCount
        pushBeat()
        WidgetBridge.updateLiveWorkout(
            active: true,
            boulders: liveAttempts,
            climbing: manualClimbing,
            phaseSince: manualClimbing ? climbingSince : restStartedAt,
            restTargetS: restTargetS
        )
    }

    /// Which phase the live view should paint itself (#243). Delegates to the
    /// pure mapping in SendLogWatchCore — the full-screen fill and the phase
    /// timer read the same resolver, so the colour can never disagree with the
    /// countdown it sits behind. `now` is passed in by the caller's
    /// `TimelineView` tick so rest-over flips without any stored state.
    func livePhase(at now: Date) -> WorkoutPhase {
        WorkoutPhasePalette.phase(
            manualClimbing: manualClimbing,
            climbingSince: climbingSince,
            restStartedAt: restStartedAt,
            restTargetS: restTargetS,
            now: now
        )
    }

    /// Snapshot state and fire one best-effort live heartbeat — over Supabase
    /// (web mirror + fallback) AND, when the phone is reachable, directly over
    /// WatchConnectivity for a sub-second in-app mirror (no network hop).
    private func pushBeat() {
        guard let sync = liveSync else { return }
        let hr = heartRate
        let count = liveAttempts
        let kcal = activeKcal
        let gain = detector.totalElevationGainM
        let climbing = detector.snapshot.isClimbing
        let cs = climbingSince
        let rs = restStartedAt
        let rt = restTargetS
        let started = startDate ?? Date()
        Task {
            await sync.beat(
                hr: hr, attemptCount: count, activeKcal: kcal,
                elevationGainM: gain, climbing: climbing,
                climbingSince: cs, restStartedAt: rs, restTargetS: rt
            )
        }
        // Bluetooth-fast path: same shape as the live_workouts row (dates as
        // epoch seconds). Fire-and-forget; the phone plugin forwards it to
        // the WebView, which keeps whichever source is newest.
        let session = WCSession.default
        if session.activationState == .activated, session.isReachable {
            var msg: [String: Any] = [
                "kind": "liveWorkout",
                "status": "live",
                "started_at": started.timeIntervalSince1970,
                "attempt_count": count,
                "climbing": climbing,
                "elevation_gain_m": gain,
                "rest_target_s": rt,
                "updated_at": Date().timeIntervalSince1970,
            ]
            if let hr { msg["hr"] = hr }
            msg["active_kcal"] = kcal
            if let cs { msg["climbing_since"] = cs.timeIntervalSince1970 }
            if let rs { msg["rest_started_at"] = rs.timeIntervalSince1970 }
            session.sendMessage(WatchBuild.stamp(msg), replyHandler: nil, errorHandler: nil)
        }
    }

    // MARK: Rest alarm (#476 F5: hoisted out of WorkoutLiveView)

    /// Double haptic when the rest countdown hits zero — cuts through gym
    /// noise, same as the old manual RestTimer. Idempotent: always cancels
    /// any existing alarm first, so it's safe to call on every
    /// `restStartedAt`/`restTargetS` change without double-scheduling.
    private func scheduleRestAlarm() {
        cancelRestAlarm()
        guard let rest = restStartedAt else { return }
        let end = rest.addingTimeInterval(Double(restTargetS))
        let interval = end.timeIntervalSinceNow
        guard interval > 0 else { return }
        // Re-review R3b: `scheduleRestAlarm()` itself isn't `@MainActor` (it's
        // called from `restTargetS`'s `didSet`, a synchronous nonisolated
        // context that can't call an isolated method directly), so a plain
        // `Task { … }` here would NOT inherit MainActor isolation the way it
        // did pre-hoist, when this lived on a SwiftUI View (implicitly
        // MainActor). `@MainActor in` requests it explicitly instead, same
        // pattern this file already uses for HealthKit's background delegate
        // callbacks below — WKInterfaceDevice haptics belong on the main
        // thread, and `restAlarmTask` must only ever be touched from there.
        restAlarmTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            WKInterfaceDevice.current().play(.notification)
            try? await Task.sleep(for: .seconds(0.6))
            WKInterfaceDevice.current().play(.notification)
        }
    }

    private func cancelRestAlarm() {
        restAlarmTask?.cancel()
        restAlarmTask = nil
    }

    /// Refit the ridge RPE model in the background if it's stale. Fitting at
    /// start (not end) keeps end() instant and offline-safe.
    private func refitRPEModelIfStale() {
        let t = tunables
        let existing = RPEModelStore.load()
        let stale = existing.map { Date().timeIntervalSince($0.fittedAt) > t.rpeModelMaxAgeS } ?? true
        guard stale else { return }
        Task.detached(priority: .background) {
            guard let rows = try? await Repo.fetchLabeledWorkouts() else { return }
            let labeled = rows.compactMap { r -> LabeledWorkout? in
                guard let rpe = r.rpeConfirmed, let effort = r.meanEffort else { return nil }
                let hrr = r.avgHr.map { max(0, min(1, ($0 - t.restHR) / (t.maxHR - t.restHR))) } ?? 0
                return LabeledWorkout(
                    sessionHRR: hrr,
                    meanEffort: effort,
                    attemptsPer10min: r.attemptsPer10min ?? 0,
                    rpe: rpe
                )
            }
            if let model = RPEModelFitter.fit(
                rows: labeled, lambda: t.rpeRidgeLambda, minSamples: t.rpeMinTrainingSamples
            ) {
                RPEModelStore.save(model)
            }
        }
    }

    @MainActor
    func end() async -> WorkoutSummary? {
        // #477: stop any further partial flush from starting, and await
        // whichever one is already in flight, BEFORE anything else — cancelling
        // it would not stop a request already on the wire from being committed
        // by the server after this call's own final write, so awaiting is the
        // only way to guarantee ordering. This runs unconditionally, ahead of
        // the session/builder guard below, so it still drains a flush that was
        // started against a workout whose session has since gone away.
        partialFlushSuspended = true
        if let partialFlushTask {
            _ = await partialFlushTask.value
        }
        partialFlushTask = nil

        guard let session, let builder, let startDate else { return nil }
        fusionTimer?.invalidate()
        fusionTimer = nil
        cancelRestAlarm() // no more rest to alarm for once the workout is ending
        altimeter.stopRelativeAltitudeUpdates()
        motion.stopDeviceMotionUpdates()
        // Close the phone's WC mirror immediately (Supabase markEnded follows).
        let wc = WCSession.default
        if wc.activationState == .activated, wc.isReachable {
            wc.sendMessage(
                WatchBuild.stamp(
                    ["kind": "liveWorkout", "status": "ended",
                     "updated_at": Date().timeIntervalSince1970]
                ),
                replyHandler: nil, errorHandler: nil
            )
        }

        let endDate = Date()
        session.end()
        do {
            try await builder.endCollection(at: endDate)
            try await builder.finishWorkout() // saves the workout to Health
        } catch {
            // Health save failure shouldn't lose the climbing data
            errorMsg = error.localizedDescription
        }

        let attempts = detector.finalize()
        let avgHR = builder.statistics(for: HKQuantityType(.heartRate))?
            .averageQuantity()?
            .doubleValue(for: .count().unitDivided(by: .minute()))
        let maxHR = builder.statistics(for: HKQuantityType(.heartRate))?
            .maximumQuantity()?
            .doubleValue(for: .count().unitDivided(by: .minute()))
        let kcal = builder.statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?
            .doubleValue(for: .kilocalorie())

        // Mark the live row ended — this runs before the confirm screen, so it
        // covers both Save and Discard (no separate Discard hook needed).
        await liveSync?.markEnded()
        liveSync = nil

        self.session = nil
        self.builder = nil
        self.startDate = nil
        isRunning = false

        let durationS = endDate.timeIntervalSince(startDate)

        // Fitted ridge model when available, hand formula otherwise.
        let predictedRPE: Double
        if let model = RPEModelStore.load(), durationS > 0 {
            let hrr = avgHR.map { max(0, min(1, ($0 - tunables.restHR) / (tunables.maxHR - tunables.restHR))) } ?? 0
            let meanEffort = attempts.isEmpty
                ? 0.0 : attempts.map(\.effortScore).reduce(0, +) / Double(attempts.count)
            predictedRPE = model.predict(
                sessionHRR: hrr,
                meanEffort: meanEffort,
                attemptsPer10min: Double(attempts.count) / (durationS / 600.0)
            )
        } else {
            predictedRPE = AttemptDetector.predictRPE(
                attempts: attempts, avgHR: avgHR, durationS: durationS, tunables: tunables
            )
        }

        return WorkoutSummary(
            workoutId: workoutId,
            startedAt: startDate,
            endedAt: endDate,
            avgHR: avgHR,
            maxHR: maxHR,
            activeKcal: kcal,
            elevationGainM: attempts.reduce(0) { $0 + max(0, $1.elevationGainM) },
            attempts: attempts,
            predictedRPE: predictedRPE,
            rawTrace: rawTrace
        )
    }

    // MARK: Save path (#476: hoisted out of WorkoutLiveView, see the state
    // group's doc comment above)

    // Stopping SAVES immediately (no confirm form) — banks the model's
    // predicted RPE + detected boulders and persists locally; the upload
    // drains in the background. Adjust RPE/type later on the phone.
    @MainActor
    func endAndSave() {
        ending = true
        Task {
            guard let summary = await end() else {
                ending = false
                return
            }
            let bundle = Repo.makeSaveBundle(
                summary: summary,
                boulders: summary.attempts.count,
                // Bank the model's raw prediction at 0.1 precision (#107) —
                // no rounding to half-points, adjust later on the phone. The
                // 0.5-step steppers are for MANUAL entry only (SL-89).
                rpe: RPEQuantization.autoTracked(summary.predictedRPE),
                phase: cachedPhase,
                tunables: .default
            )
            WidgetBridge.updateLiveWorkout(active: false) // clear the live widget
            await save(bundle)
        }
    }

    @MainActor
    func retryFailedSave() {
        guard let failedBundle, !ending else { return }
        ending = true
        Task { await save(failedBundle) }
    }

    @MainActor
    private func save(_ bundle: WorkoutSaveBundle) async {
        let outcome = await OfflineQueue.shared.enqueue(bundle)
        guard outcome != .lost else {
            failedBundle = bundle
            ending = false
            WKInterfaceDevice.current().play(.failure)
            return
        }

        // Re-review R1: only clear THIS bundle's failure. `failedBundle` can
        // now belong to an EARLIER, unrelated workout — Start being
        // unblocked (F1) means the user can start and successfully save
        // workout N+1 while N's failed bundle is still sitting there
        // waiting on Retry. Clearing unconditionally silently discarded N's
        // last in-memory copy while telling the user "Saved" — the exact
        // kind of swallowed data loss CLAUDE.md #264 forbids. The id-match
        // decision itself lives in Core (`FailedBundleClear`, X1) — this is
        // its only production call site.
        if FailedBundleClear.shouldClear(failedId: failedBundle?.workout.id, savedId: bundle.workout.id) {
            failedBundle = nil
        }
        await WidgetBridge.refreshStatus() // fresh ACWR after the save
        if outcome == .queued {
            stillQueued = await OfflineQueue.shared.pendingCount() > 0
        } else {
            stillQueued = false
        }
        ending = false
        justSaved = true
        WKInterfaceDevice.current().play(.success)
        try? await Task.sleep(for: .seconds(1.6))
        justSaved = false
    }

    // MARK: Sensors

    private func startAltimeter() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            self.rawRelativeAltitude = data.relativeAltitude.doubleValue
        }
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.05 // 20 Hz
        motion.startDeviceMotionUpdates(to: .main) { [weak self] dm, _ in
            guard let self, let dm, let startDate = self.startDate else { return }
            let a = dm.userAcceleration
            let mag = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            let t = Date().timeIntervalSince(startDate)
            self.accelBuffer.append((t, mag))
            let cutoff = t - self.tunables.motionWindowS
            if let firstValid = self.accelBuffer.firstIndex(where: { $0.t >= cutoff }), firstValid > 0 {
                self.accelBuffer.removeFirst(firstValid)
            }
        }
    }

    /// The production entry point for a new HR reading — the HealthKit
    /// delegate below calls this after extracting `HeartRateSample` from
    /// `HKStatistics`. Not `private`: constructing a real `HKStatistics`
    /// off-device isn't possible (no public initializer), so SendLogWatchTests
    /// drives the monotonic-reject path through this method directly rather
    /// than through the delegate callback (#477).
    func acceptHeartRate(_ candidate: HeartRateSample) {
        hrTimeline.accept(candidate)
    }

    // Not `private`: see the `fusionTimer` comment above.
    func startFusion() {
        // Review finding F3: the issue's own root-cause description is
        // "startFusion overwrites fusionTimer without invalidating it" — the
        // original fix only guarded `start()`, the one caller, but this
        // function is `internal` and callable from anywhere in the module.
        // Invalidating here makes the invariant local to the function that
        // owns `fusionTimer`, rather than depending on every future caller
        // remembering to guard it (the repo's #295/#296 pattern).
        fusionTimer?.invalidate()
        fusionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / tunables.tickHz, repeats: true) { [weak self] _ in
            self?.performFusionTick(now: Date())
        }
    }

    /// Not `private`: SendLogWatchTests calls this directly with a
    /// controlled `now` (and a manually-set `startDate`) to drive HR
    /// staleness deterministically — see the `startDate`/`rawTrace`/
    /// `lastMotionSample` comments above (#477).
    func performFusionTick(now: Date) {
        guard let startDate else { return }
        let t = now.timeIntervalSince(startDate)
        self.elapsed = t

        let rms: Double
        if accelBuffer.isEmpty {
            rms = 0
        } else {
            let sumSq = accelBuffer.reduce(0) { $0 + $1.mag * $1.mag }
            rms = (sumSq / Double(accelBuffer.count)).squareRoot()
        }

        let alt = rawRelativeAltitude
        // #477: recomputed every tick from the timestamped timeline rather
        // than read as whatever `didCollectDataOf` last happened to assign.
        // A reading that hasn't been refreshed within `hrStaleAfterS` reads
        // as nil here — and because every consumer below (the detector
        // sample, `rawTrace`, and `pushBeat`'s phone/Supabase heartbeat)
        // reads THIS property, the staleness rule can't be applied to one
        // and missed by another.
        heartRate = hrTimeline.freshValue(at: now, maxAgeS: tunables.hrStaleAfterS)
        let sample = MotionSample(t: t, altitude: alt, motionRMS: rms, hr: heartRate)
        lastMotionSample = sample
        let before = detector.snapshot
        let countBefore = liveAttempts
        detector.ingest(sample, at: now)
        let after = detector.snapshot
        let countAfter = detector.liveAttemptCount
        liveAttempts = countAfter
        relativeAltitude = after.localHeightM
        let stateChanged = before.state != after.state
        if stateChanged {
            if after.isClimbing {
                climbingSince = after.phaseStartedAt ?? now
                restStartedAt = nil
                cancelRestAlarm()
            } else {
                climbingSince = nil
                restStartedAt = now
                scheduleRestAlarm()
            }
            // Publish the observable phase only after its clock is ready.
            manualClimbing = after.isClimbing
            pushBeat()
        }
        // #476: liveAttemptCount can cross AttemptDetector's post-filter
        // threshold mid-attempt with no phase transition (see
        // WidgetCountSync's doc comment) — pushing only on `stateChanged`
        // left the widget's boulder count stuck until the attempt ended.
        if WidgetCountSync.shouldPush(stateChanged: stateChanged, countBefore: countBefore, countAfter: countAfter) {
            WidgetBridge.updateLiveWorkout(
                active: true, boulders: countAfter,
                climbing: after.isClimbing,
                phaseSince: after.isClimbing ? climbingSince : restStartedAt,
                restTargetS: restTargetS
            )
        }

        if tunables.keepRawTrace && fusionTick % tunables.rawTraceStride == 0 {
            rawTrace.append([t.rounded(), (alt * 100).rounded() / 100, (rms * 1000).rounded() / 1000, heartRate])
        }

        // Live heartbeat every 5th tick (~5s) — best-effort, off the timer.
        fusionTick += 1
        if fusionTick % 5 == 0 {
            pushBeat()
        }
        // Durable flush every ~2 min (SL-90) — the trace-so-far survives a
        // crash/dead battery instead of living only in memory until End.
        if fusionTick % 120 == 0 {
            flushPartial()
        }
    }

    /// Merge-upsert the in-progress climb_workouts row with everything known
    /// so far. Best-effort: a failure just waits for the next flush or the
    /// end-of-workout upload (which overwrites this row with final stats).
    ///
    /// Not `private`: SendLogWatchTests calls this directly (with
    /// `partialUploader` swapped for a deferred fake) to drive the
    /// coalescing/await behaviour deterministically (#477).
    func flushPartial() {
        // `end()` has already claimed ownership of finishing this workout —
        // a coalesced rerun starting now would race the final row exactly
        // like the un-awaited detached Task this replaces used to.
        guard !partialFlushSuspended else { return }
        switch partialFlushDrain.request() {
        case .queued:
            // One is already in flight; it will pick up the LATEST snapshot
            // (not this moment's) when it finishes — see `runPartialFlush()`.
            return
        case .start:
            runPartialFlush()
        }
    }

    private func runPartialFlush() {
        guard let startDate else {
            // Nothing to snapshot; resolve the drain so a later legitimate
            // request isn't wedged behind a request that can never run.
            _ = partialFlushDrain.completePass()
            return
        }
        let partial = ClimbWorkoutPartialUpsert(
            id: workoutId,
            startedAt: startDate,
            endedAt: Date(),
            elevationGainM: detector.totalElevationGainM,
            attemptsDetected: liveAttempts,
            attemptsConfirmed: liveAttempts,
            raw: tunables.keepRawTrace ? rawTrace : nil
        )
        let uploader = partialUploader
        let task = Task.detached(priority: .background) {
            await uploader(partial)
        }
        partialFlushTask = task
        Task { @MainActor [weak self] in
            _ = await task.value
            guard let self else { return }
            self.partialFlushTask = nil
            guard !self.partialFlushSuspended else {
                // `end()` is waiting on (or has already moved past) this
                // exact task — resolve the drain but never start a rerun;
                // a rerun starting after `end()` began would be exactly the
                // race this fix exists to close.
                _ = self.partialFlushDrain.completePass()
                return
            }
            if self.partialFlushDrain.completePass() == .rerun {
                // #477: one or more flushes were requested while this one
                // was in flight — coalesce them into exactly one more run,
                // built from state as of NOW, not as of the earlier request.
                self.runPartialFlush()
            }
        }
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WorkoutManager: HKWorkoutSessionDelegate {
    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {}

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.errorMsg = error.localizedDescription
        }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        // #477: gather every candidate synchronously, on this callback's own
        // thread, THEN hop to MainActor once for the whole batch — collapsing
        // the old per-type `Task { @MainActor }` reduces how often two
        // callbacks' follow-up work can land out of order. It does not, by
        // itself, guarantee it never does (two separate invocations of this
        // delegate method can still race each other's Tasks) — `acceptHeartRate`
        // is what actually enforces ordering, via `HeartRateTimeline.accept`.
        var hrCandidate: HeartRateSample?
        var kcalCandidate: Double?
        for type in collectedTypes {
            guard let quantityType = type as? HKQuantityType,
                  let stats = workoutBuilder.statistics(for: quantityType) else { continue }
            switch quantityType {
            case HKQuantityType(.heartRate):
                // #477: the SAMPLE time HealthKit reports this reading as
                // covering — not `Date()`, which would measure when this
                // callback happened to be delivered, not sensor age.
                if let value = stats.mostRecentQuantity()?.doubleValue(for: .count().unitDivided(by: .minute())),
                   let sampleAt = stats.mostRecentQuantityDateInterval()?.end {
                    hrCandidate = HeartRateSample(value: value, sampleAt: sampleAt)
                }
            case HKQuantityType(.activeEnergyBurned):
                kcalCandidate = stats.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
            default:
                break
            }
        }
        Task { @MainActor in
            if let hrCandidate {
                self.acceptHeartRate(hrCandidate)
            }
            if let kcalCandidate {
                self.activeKcal = kcalCandidate
            }
        }
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
