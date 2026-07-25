import CoreMotion
import Foundation
import HealthKit
import Observation
import SendLogWatchCore
import WatchConnectivity

/// Runs an HKWorkoutSession (climbing, indoor) with live HR from
/// HKLiveWorkoutBuilder, fused at 1 Hz with CMAltimeter relative altitude and
/// a 2 s RMS of CMMotionManager userAcceleration into the AttemptDetector.
@Observable
final class WorkoutManager: NSObject {
    var isRunning = false
    var heartRate: Double?
    var activeKcal: Double = 0
    var elapsed: TimeInterval = 0
    var relativeAltitude: Double = 0
    var liveAttempts = 0
    /// True while a manual boulder is open (Boulder/Stop button).
    var manualClimbing = false
    /// When the current manual boulder started (nil while resting).
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
    private var fusionTimer: Timer?
    private var startDate: Date?
    private var maxAltitudeSeen: Double = 0
    private var minAltitudeSeen: Double = 0
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
        errorMsg = nil
        // Warm the phase in the background so save-on-stop needs no network.
        Task { cachedPhase = (try? await Repo.fetchCurrentPhase()) ?? "capacity" }
        detector = AttemptDetector(tunables: tunables)
        rawTrace = []
        accelBuffer = []
        heartRate = nil
        activeKcal = 0
        elapsed = 0
        relativeAltitude = 0
        liveAttempts = 0
        manualClimbing = false
        climbingSince = nil
        restStartedAt = nil
        maxAltitudeSeen = 0
        minAltitudeSeen = 0
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

    /// Toggle a manual boulder attempt (Boulder ⇄ Stop). Auto detection is
    /// suspended while one is open. Stopping drops straight into the rest
    /// countdown (phone-workout logic); both transitions beat immediately so
    /// the phone mirror flips without waiting for the 5 s heartbeat.
    @MainActor
    func toggleManualAttempt() {
        let now = Date()
        if detector.isManualAttemptOpen {
            detector.endManualAttempt(at: now)
            climbingSince = nil
            restStartedAt = now
        } else {
            detector.beginManualAttempt(at: now)
            climbingSince = now
            restStartedAt = nil
        }
        manualClimbing = detector.isManualAttemptOpen
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

    /// Snapshot state and fire one best-effort live heartbeat — over Supabase
    /// (web mirror + fallback) AND, when the phone is reachable, directly over
    /// WatchConnectivity for a sub-second in-app mirror (no network hop).
    private func pushBeat() {
        guard let sync = liveSync else { return }
        let hr = heartRate
        let count = liveAttempts
        let kcal = activeKcal
        let gain = max(0, maxAltitudeSeen - minAltitudeSeen)
        let climbing = detector.isManualAttemptOpen
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
            session.sendMessage(msg, replyHandler: nil, errorHandler: nil)
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
                ["kind": "liveWorkout", "status": "ended",
                 "updated_at": Date().timeIntervalSince1970],
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
            elevationGainM: max(0, maxAltitudeSeen - minAltitudeSeen),
            attempts: attempts,
            predictedRPE: predictedRPE,
            rawTrace: rawTrace
        )
    }

    // MARK: Sensors

    private func startAltimeter() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            self.relativeAltitude = data.relativeAltitude.doubleValue
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

    private func startFusion() {
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

            let alt = self.relativeAltitude
            self.maxAltitudeSeen = max(self.maxAltitudeSeen, alt)
            self.minAltitudeSeen = min(self.minAltitudeSeen, alt)

            let sample = MotionSample(t: t, altitude: alt, motionRMS: rms, hr: self.heartRate)
            self.detector.ingest(sample, at: now)
            self.liveAttempts = self.detector.liveAttemptCount

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
            elevationGainM: max(0, maxAltitudeSeen - minAltitudeSeen),
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
