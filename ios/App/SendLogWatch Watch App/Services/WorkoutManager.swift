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
    /// (issue #189).
    var stillQueued = false
    /// Kept in memory after both persistence and direct upload fail (#287),
    /// so Retry can replay the same idempotent bundle instead of pretending
    /// the workout was saved.
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
    private var startDate: Date?
    private var rawRelativeAltitude: Double = 0
    private var rawTrace: [[Double?]] = []
    // Generated at start so the live_workouts heartbeat and the final
    // climb_workouts row share one id (web correlation).
    private var workoutId = UUID()
    private var liveSync: LiveWorkoutSync?
    private var fusionTick = 0

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

        errorMsg = nil
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
        } else {
            detector.beginManualAttempt(at: now)
            climbingSince = now
            restStartedAt = nil
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
        guard let session, let builder, let startDate else { return nil }
        fusionTimer?.invalidate()
        fusionTimer = nil
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

        failedBundle = nil
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

    // Not `private`: see the `fusionTimer` comment above.
    func startFusion() {
        fusionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / tunables.tickHz, repeats: true) { [weak self] _ in
            guard let self, let startDate = self.startDate else { return }
            let now = Date()
            let t = now.timeIntervalSince(startDate)
            self.elapsed = t

            let rms: Double
            if self.accelBuffer.isEmpty {
                rms = 0
            } else {
                let sumSq = self.accelBuffer.reduce(0) { $0 + $1.mag * $1.mag }
                rms = (sumSq / Double(self.accelBuffer.count)).squareRoot()
            }

            let alt = self.rawRelativeAltitude
            let sample = MotionSample(t: t, altitude: alt, motionRMS: rms, hr: self.heartRate)
            let before = self.detector.snapshot
            let countBefore = self.liveAttempts
            self.detector.ingest(sample, at: now)
            let after = self.detector.snapshot
            let countAfter = self.detector.liveAttemptCount
            self.liveAttempts = countAfter
            self.relativeAltitude = after.localHeightM
            let stateChanged = before.state != after.state
            if stateChanged {
                if after.isClimbing {
                    self.climbingSince = after.phaseStartedAt ?? now
                    self.restStartedAt = nil
                } else {
                    self.climbingSince = nil
                    self.restStartedAt = now
                }
                // Publish the observable phase only after its clock is ready;
                // WorkoutLiveView's onChange schedules/cancels the rest alarm.
                self.manualClimbing = after.isClimbing
                self.pushBeat()
            }
            // #476: liveAttemptCount can cross AttemptDetector's post-filter
            // threshold mid-attempt with no phase transition (see
            // WidgetCountSync's doc comment) — pushing only on `stateChanged`
            // left the widget's boulder count stuck until the attempt ended.
            if WidgetCountSync.shouldPush(stateChanged: stateChanged, countBefore: countBefore, countAfter: countAfter) {
                WidgetBridge.updateLiveWorkout(
                    active: true, boulders: countAfter,
                    climbing: after.isClimbing,
                    phaseSince: after.isClimbing ? self.climbingSince : self.restStartedAt,
                    restTargetS: self.restTargetS
                )
            }

            if self.tunables.keepRawTrace
                && self.fusionTick % self.tunables.rawTraceStride == 0 {
                self.rawTrace.append([t.rounded(), (alt * 100).rounded() / 100, (rms * 1000).rounded() / 1000, self.heartRate])
            }

            // Live heartbeat every 5th tick (~5s) — best-effort, off the timer.
            self.fusionTick += 1
            if self.fusionTick % 5 == 0 {
                self.pushBeat()
            }
            // Durable flush every ~2 min (SL-90) — the trace-so-far survives a
            // crash/dead battery instead of living only in memory until End.
            if self.fusionTick % 120 == 0 {
                self.flushPartial()
            }
        }
    }

    /// Merge-upsert the in-progress climb_workouts row with everything known
    /// so far. Best-effort: a failure just waits for the next flush or the
    /// end-of-workout upload (which overwrites this row with final stats).
    private func flushPartial() {
        guard let startDate else { return }
        let partial = ClimbWorkoutPartialUpsert(
            id: workoutId,
            startedAt: startDate,
            endedAt: Date(),
            elevationGainM: detector.totalElevationGainM,
            attemptsDetected: liveAttempts,
            attemptsConfirmed: liveAttempts,
            raw: tunables.keepRawTrace ? rawTrace : nil
        )
        Task.detached(priority: .background) {
            try? await Repo.flushPartialWorkout(partial)
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
        for type in collectedTypes {
            guard let quantityType = type as? HKQuantityType,
                  let stats = workoutBuilder.statistics(for: quantityType) else { continue }
            Task { @MainActor in
                switch quantityType {
                case HKQuantityType(.heartRate):
                    self.heartRate = stats.mostRecentQuantity()?
                        .doubleValue(for: .count().unitDivided(by: .minute()))
                case HKQuantityType(.activeEnergyBurned):
                    self.activeKcal = stats.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
                default:
                    break
                }
            }
        }
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
