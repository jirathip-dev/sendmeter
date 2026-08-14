import CoreMotion
import Foundation
import HealthKit
import Observation
import os
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
    /// True when `stillQueued` is true SPECIFICALLY because the just-saved
    /// bundle is held for an account other than the one currently signed in
    /// (#529 F3) — `pendingCount()` deliberately excludes such an item from
    /// the CURRENT account's count (#158/#189: it isn't B's problem), which
    /// otherwise made a held A-owned save read as `stillQueued == false`
    /// right after it happened — the copy reserved for an item that
    /// actually uploaded. An ordinary "still syncing under my own account"
    /// queued state and "held until the account that started this run signs
    /// back in" must not share that copy. See `WorkoutLiveView.savedContent`.
    var stillQueuedForAnotherAccount = false
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

    /// Stable account identity captured the moment `start()` accepts a run
    /// (issue #529) — mirrors `GuidedForceRunner.ownerUserId`. Unlike a
    /// guided Force run, an ordinary workout does NOT discard itself on a
    /// later account change: an `HKWorkoutSession` is a live recording the
    /// user is mid-climb inside, so this stays fixed at the account that
    /// started it and is never re-read from `userIdProvider()` again for
    /// this run — `endAndSave()`/`retryFailedSave()` stamp every save with
    /// this value, so an A → signed-out/B transition holds the eventual
    /// save under A (`shouldDrain`) instead of silently uploading it under
    /// whichever account is signed in when Stop is finally tapped.
    private(set) var ownerUserId: UUID?

    @ObservationIgnored private let userIdProvider: @Sendable () -> UUID?

    private static func loadRestTarget() -> Int {
        let v = UserDefaults.standard.integer(forKey: "restTargetS")
        return [60, 120, 180, 300].contains(v) ? v : 180
    }

    private let tunables: Tunables
    private var detector: AttemptDetector
    private let healthStore = HKHealthStore()
    /// Internal authorization seam for the app-target tests. Production leaves
    /// this nil and uses the real HealthKit request below; tests inject a
    /// deterministic failure so start-guard behavior never depends on host
    /// HealthKit entitlements or an OS authorization prompt.
    @ObservationIgnored
    var authorizationRequestOverride: (() async throws -> Void)?
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
    /// #521: both WatchConnectivity and Supabase carry the same run identity
    /// and sequence. Allocation happens synchronously on the manager's state
    /// owner before either transport task can suspend.
    private var liveMirrorSequence = LiveMirrorSequence(runId: UUID())
    /// #614: direct-send failure bookkeeping for the CURRENT run. Only ever
    /// touched on the main thread — the WC reply/error handlers hop to main,
    /// and every `pushBeat` caller is main — matching the existing
    /// unsynchronized `liveMirrorSequence` access. A success (the phone's
    /// ack) resets `consecutiveFailures` so a healthy stretch never eats
    /// into the retry cap; `retryInFlight` dedupes non-terminal re-sends to
    /// one pending at a time.
    private var directSendConsecutiveFailures = 0
    private var directRetryInFlight = false
    /// #614 review F5: supersedes a pending retry when a terminal failure
    /// pre-empts it. Every scheduled closure captures the token at schedule
    /// time and bails when the live token has moved on, so an End failure
    /// cancels a pending `count`/`phase` retry in favour of its own.
    private var directRetryToken = 0
    /// #614 review F5: terminal (End) re-sends this run — a separate budget
    /// from `directSendConsecutiveFailures` (see `DirectBeatRetryPolicy`).
    private var directSendTerminalRetries = 0
    /// Total direct-send failures this run (send error OR unreachable skip
    /// on an ack-capable phone), reset at `start()`. Surfaced via the
    /// end-of-workout Console breadcrumb. `internal` on purpose (review F9):
    /// `WorkoutSavePathResetTests` injects a non-zero value and pins that
    /// `start()` actually clears it — production only writes it from
    /// `directSendFailed` (and reads it at `end()`).
    var directSendFailures = 0
    private var liveSync: LiveWorkoutSync?
    private var fusionTick = 0
    /// Sample-timestamped, monotonic HR — see `HeartRateTimeline`'s doc
    /// comment (#477). Replaces the old bare `didCollectDataOf` → `heartRate`
    /// assignment, which held whatever arrived last with no age and no
    /// protection against an out-of-order callback moving it backwards.
    private var hrTimeline = HeartRateTimeline()
    private static let log = Logger(subsystem: "com.jirathip.sendlog.watchkitapp", category: "workout")
    /// #477 review F4: a real HR quantity with no `mostRecentQuantityDateInterval()`
    /// can't be timestamped, so it's discarded (can't check monotonicity/
    /// staleness on a reading with no time) — see the delegate below. That
    /// IS real data loss, not a benign gap, so it's worth a one-shot Console
    /// breadcrumb per workout rather than total silence. Not `errorMsg`:
    /// that's user-facing and would alarm the user over what may be a
    /// one-tick HealthKit quirk. Not `private`: `os_log`/`Logger` output
    /// isn't observable from a unit test, so this flag — the thing that
    /// actually makes the "once" behavior real — is what SendLogWatchTests
    /// asserts on instead.
    var hrMissingDateIntervalLogged = false
    /// #481 (#477 F4 follow-up): `hrMissingDateIntervalLogged` only says
    /// whether Console has been told at all — it can't distinguish a single
    /// blip from a whole workout of untimestampable readings. This counts
    /// every occurrence regardless of the one-shot log gate; `end()` reports
    /// the total.
    var hrMissingDateIntervalCount = 0
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
    /// #477 re-review R1: bumped in `start()`'s reset block, on the line
    /// beside `partialFlushDrain = CoalescingDrain()` — deliberately NOT
    /// `startGuard.generation`. That counter answers "has any `start()` call
    /// been ACCEPTED since?", and `begin()` increments it before `start()`'s
    /// `guard !isRunning else { return }` can reject the call — so a start()
    /// rejected by `!isRunning` (isRunning already true) bumps the generation
    /// and then runs nothing else: `partialFlushDrain` is NOT replaced, but
    /// the old generation stamp is no longer current. The completion handler
    /// in `runPartialFlush()` would then bail on a drain that's still the
    /// live one, without ever calling `completePass()` — wedging it `running`
    /// forever with nothing left to un-stick it (durable flushing silently
    /// dead for the rest of the workout: the exact SL-90/#470 loss this
    /// mechanism exists to prevent). This counter only ever advances in the
    /// SAME reset block that replaces the drain, so "my epoch is still
    /// current" and "my drain is still the live one" can never disagree.
    private var partialFlushEpoch = 0
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
    /// #481 review F8: extracted out of `phaseWarmer`'s default closure so
    /// the CONDITION — the thing that can regress (inverted, deleted by a
    /// well-meaning "no test-awareness in production code" tidy-up) — is
    /// independently inspectable and assertable, rather than folded into a
    /// closure whose only observable output (`"capacity"`) is also what the
    /// unguarded path returns in every environment this suite runs in (dead
    /// port → `try?` swallows the failure; a live-but-unauthenticated stack
    /// → 401 → same; `Repo.fetchCurrentPhase` itself falls back to
    /// `"capacity"` on an empty result). A pin on the return value alone
    /// cannot fail; `testWorkoutManagerIsRunningUnderTestHostDuringTests`
    /// (`WorkoutOwnershipTests.swift`) asserts on this property directly.
    static let isRunningUnderTestHost = NSClassFromString("XCTestCase") != nil
    /// Not `private`: `WorkoutOwnershipTests.swift` calls this directly
    /// (`@testable import` only reaches `internal`+) to prove the DEFAULT —
    /// not an override — is what resolves under test. `start()` fires this
    /// in the background so save-on-stop needs no network round trip. #481:
    /// left as a bare `Repo.fetchCurrentPhase()` call, this dialed
    /// 127.0.0.1:54321 from every test that calls `start()` — a measured
    /// 2-in-5 flake at ~32s/run. #481 review F1/F5/F6: an injectable
    /// per-instance property only closes that hole for constructions that
    /// remember to override it — a round-1 fix that instead tried to
    /// STATICALLY SCAN the test target for missed overrides turned out to be
    /// evadable by ordinary XCTest idioms (`setUp()` + a stored property, a
    /// computed-property factory, a cross-file factory, a factory that calls
    /// `start()` itself) and could silently stop scanning partway through a
    /// file — a pin that can go quiet is not a pin. The actual fix is
    /// constructional, not conventional: the DEFAULT closure itself checks
    /// `isRunningUnderTestHost` and returns the same fallback `start()`
    /// already used for a failed fetch, before ever reaching `Repo`. This
    /// makes every construction shape safe — including ones nobody has
    /// written yet — with nothing to remember and nothing to scan for.
    var phaseWarmer: () async -> String = {
        guard !WorkoutManager.isRunningUnderTestHost else { return "capacity" }
        return (try? await Repo.fetchCurrentPhase()) ?? "capacity"
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

    init(
        tunables: Tunables = .default,
        userIdProvider: @escaping @Sendable () -> UUID? = { WatchSessionStore.shared.userId }
    ) {
        self.tunables = tunables
        self.detector = AttemptDetector(tunables: tunables)
        self.userIdProvider = userIdProvider
        super.init()
    }

    // #481: this used to carry a `deinit { fusionTimer?.invalidate() }`,
    // added when `WorkoutManager` was `@State` inside `WorkoutLiveView` (a
    // navigationDestination) and really could deallocate mid-workout (a nav
    // pop). It was also never correctly thread-safe where it WAS reachable:
    // `Timer.invalidate()` must be called from the thread that installed the
    // timer (`startFusion()`, always MainActor-adjacent), but `deinit`
    // carries no isolation and could in principle run on whatever thread
    // drops the last strong reference.
    //
    // The invariant that makes it safe to remove — no view owns its own
    // `WorkoutManager`, so nothing deallocates it mid-workout — is #476's
    // rule, not a fact about which views happen to exist today: any view
    // that ever gains `@State private var workout = WorkoutManager()` and
    // calls `start()` reintroduces both #476's orphaned-session bug and the
    // orphaned run-loop timer this `deinit` used to mop up, with nothing left
    // to catch it. Today the rule is pinned only per-view, by
    // `testWorkoutLiveViewReadsWorkoutManagerFromEnvironmentNotState` /
    // `testRootViewReadsWorkoutManagerFromEnvironmentNotState`
    // (`WorkoutOwnershipTests.swift`) — a NEW view needs its own such pin, or
    // its own `deinit` guard, not a free pass from this comment. `end()` (and
    // `stopRecordingAndAwaitInFlightPartial()`) is the one real invalidation
    // path for every view that follows the rule, and it already runs on
    // MainActor.

    func requestAuthorization() async throws {
        if let authorizationRequestOverride {
            try await authorizationRequestOverride()
            return
        }
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
        stillQueuedForAnotherAccount = false
        // Review finding F7: defensive — every path that sets these also
        // runs `end()`, which nils them, so this isn't reachable today, but
        // it closes the same "long-lived manager" exposure as the fields
        // above at no cost.
        session = nil
        builder = nil
        startDate = nil
        liveSync = nil
        // #529: captured once, synchronously, for THIS accepted run — never
        // re-read after this point. See `ownerUserId`'s doc comment for why
        // a workout must stay bound to the account that started it rather
        // than whoever is signed in when it's eventually saved.
        ownerUserId = userIdProvider()
        cancelRestAlarm() // review finding F5: no stale alarm from a previous rest
        // Warm the phase in the background so save-on-stop needs no network.
        // Stamped with this start's generation: once hoisted, this manager
        // outlives any single workout, so a slow fetch from a PREVIOUS start
        // must not land on the workout that's running by the time it resolves.
        Task {
            let phase = await self.phaseWarmer()
            guard self.startGuard.isCurrent(generation) else { return }
            self.cachedPhase = phase
        }
        detector = AttemptDetector(tunables: tunables)
        rawTrace = []
        accelBuffer = []
        heartRate = nil
        hrTimeline = HeartRateTimeline()
        lastMotionSample = nil
        hrMissingDateIntervalLogged = false
        hrMissingDateIntervalCount = 0
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
        liveMirrorSequence = LiveMirrorSequence(runId: workoutId)
        directSendFailures = 0
        directSendConsecutiveFailures = 0
        directRetryInFlight = false
        directRetryToken = 0
        directSendTerminalRetries = 0
        // #477: a previous workout's partial-flush bookkeeping must not
        // carry into this one — a leftover `partialFlushSuspended = true`
        // would silently disable durable flushing for the entire next
        // workout. This block only runs for an ACCEPTED start (past the
        // `!isRunning` guard above) — `partialFlushEpoch` is bumped right
        // here, beside the drain it guards, so the two can never disagree
        // about whether a given flush's drain is still the live one.
        partialFlushDrain = CoalescingDrain()
        partialFlushTask = nil
        partialFlushSuspended = false
        partialFlushEpoch &+= 1

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
            // #480: a `beginCollection` failure must not orphan the session
            // `startActivity` just made live in HealthKit — `self.session`/
            // `self.builder` are only assigned below, on success, so without
            // cleanup `end()` could never reach it. See
            // `WorkoutSessionActivation`'s doc comment (SendLogWatchCore) for
            // the full reasoning and why detach-then-end-then-discard is the
            // right order; `workoutSession(_:didFailWithError:)` and
            // `workoutBuilder(_:didCollectDataOf:)` below carry the identity
            // guard that backstops the detach.
            try await WorkoutSessionActivation.run(
                startActivity: { session.startActivity(with: start) },
                beginCollection: { try await builder.beginCollection(at: start) },
                detachDelegates: {
                    session.delegate = nil
                    builder.delegate = nil
                },
                endSession: { session.end() },
                discardBuilder: { builder.discardWorkout() }
            )

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
            // Start is discrete and must reach the phone without waiting for
            // the first five-second heartbeat.
            pushBeat(event: .start)
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
        pushBeat(event: .phase)
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
    private func pushBeat(event: LiveMirrorEvent = .telemetry) {
        guard let sync = liveSync else { return }
        // Sequence exhaustion is astronomically unlikely, but it must fail
        // closed rather than repeat Int.max and make a receiver accept a
        // duplicate terminal/live transition.
        guard let beat = liveMirrorSequence.nextIfAvailable(event: event) else { return }
        let terminal = beat.terminal
        let hr = terminal ? nil : heartRate
        let count = liveAttempts
        let kcal = terminal ? nil : activeKcal
        let gain = terminal ? 0 : detector.totalElevationGainM
        let climbing = terminal ? false : detector.snapshot.isClimbing
        let cs = terminal ? nil : climbingSince
        let rs = terminal ? nil : restStartedAt
        let rt = terminal ? nil : restTargetS
        let started = startDate ?? Date()
        Task {
            await sync.beat(
                hr: hr, attemptCount: count, activeKcal: kcal,
                elevationGainM: gain, climbing: climbing,
                climbingSince: cs, restStartedAt: rs, restTargetS: rt,
                sequence: beat.sequence, event: beat.event, terminal: terminal
            )
        }
        // Bluetooth-fast path: same shape as the live_workouts row (dates as
        // epoch seconds). Acknowledged (#614): the phone replies `[:]` on
        // receipt, and a failed/unreachable discrete transition gets one
        // short automatic re-send instead of silently waiting out the ~5s
        // heartbeat. The Supabase path above remains the durable fallback.
        sendDirectBeat(
            beat: beat, terminal: terminal, started: started,
            hr: hr, count: count, kcal: kcal, gain: gain,
            climbing: climbing, cs: cs, rs: rs, rt: rt
        )
    }

    /// Builds and sends one direct WatchConnectivity workout beat. Kept out
    /// of `pushBeat` (and shared with `retryDirectBeat`) so a retry can
    /// re-send the CURRENT snapshot with a fresh monotonic sequence without
    /// re-touching the Supabase path.
    private func sendDirectBeat(
        beat: LiveMirrorBeat,
        terminal: Bool,
        started: Date,
        hr: Double?,
        count: Int,
        kcal: Double?,
        gain: Double,
        climbing: Bool,
        cs: Date?,
        rs: Date?,
        rt: Int?
    ) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        var msg: [String: Any] = [
            "kind": "liveWorkout",
            "status": terminal ? "ended" : "live",
            "started_at": started.timeIntervalSince1970,
            "attempt_count": terminal ? 0 : count,
            "climbing": climbing,
            "elevation_gain_m": gain,
            "updated_at": Date().timeIntervalSince1970,
        ]
        msg.merge(beat.wireFields) { _, new in new }
        if let rt { msg["rest_target_s"] = rt }
        // #477 review F1: omitting the key here (rather than sending
        // NSNull()) is deliberately left as-is — `messageToLive` on the
        // phone reads `msg.hr ?? null` in JS, where an absent key is
        // already `undefined`, and `undefined ?? null` is `null`. This
        // wire format already has no analog of the LiveWorkoutUpsert bug
        // above. NSNull() is not documented as a valid WCSession
        // property-list value and risks an invalid-argument crash on
        // send — not worth it to make two already-correct paths look
        // more symmetric.
        if let hr { msg["hr"] = hr }
        msg["active_kcal"] = kcal
        if let cs { msg["climbing_since"] = cs.timeIntervalSince1970 }
        if let rs { msg["rest_started_at"] = rs.timeIntervalSince1970 }
        // #530: this run's immutable owner (#529), never re-read from
        // `userIdProvider()` here — see `ownerUserId`'s doc comment.
        msg = LiveMirrorOwnership.stamped(msg, ownerUserId: ownerUserId)
        let stamped = WatchBuild.stamp(msg)
        let runId = beat.runId
        // #614 review F6: the acknowledged-send contract is two-sided — the
        // phone only replies `[:]` on builds that carry the `ack_capable`
        // relay stamp. An OLD phone build never replies, so an ack'd send
        // would time out, be counted as a failure on a message that was
        // actually delivered, and trigger duplicate re-sends. Keep the exact
        // pre-#614 fire-and-forget behavior for a phone we have not proven
        // ack-capable.
        let ackCapable = WatchSessionStore.shared.ackCapable
        if session.isReachable {
            if ackCapable {
                // #614: replyHandler = the phone's ack (resets the failure
                // backoff so a healthy stretch never eats into the retry
                // cap); errorHandler = a dropped/disconnected send, which
                // schedules the bounded retry for a discrete transition.
                // Both handlers hop to main because the bookkeeping below is
                // main-only. `started` rides the failure path so a retry
                // re-sends the run's REAL start time, never a freshly-read
                // `Date()` after `end()` cleared `startDate`.
                session.sendMessage(
                    stamped,
                    replyHandler: { [weak self] _ in
                        DispatchQueue.main.async { self?.directSendSucceeded(runId: runId) }
                    },
                    errorHandler: { [weak self] _ in
                        DispatchQueue.main.async { self?.directSendFailed(runId: runId, event: beat.event, started: started) }
                    }
                )
            } else {
                session.sendMessage(stamped, replyHandler: nil, errorHandler: nil)
            }
        } else if ackCapable {
            // Not reachable right now — treat as a failed direct send so the
            // discrete transition still gets its one retry once the link is
            // back, instead of silently parking until the next heartbeat.
            // (An old phone gets no failure counting at all, matching its
            // pre-#614 behavior.)
            directSendFailed(runId: runId, event: beat.event, started: started)
        }
    }

    /// The phone acknowledged the direct beat. `WCSession` may report the
    /// same send's success after a failure callback raced in — harmless:
    /// resetting the counter is idempotent.
    private func directSendSucceeded(runId: UUID) {
        guard liveMirrorSequence.runId == runId else { return }
        directSendConsecutiveFailures = 0
    }

    /// A direct send failed (or was skipped as unreachable on an ack-capable
    /// phone). Counts the failure and, under the retry policy, schedules ONE
    /// re-send of the current snapshot shortly. Run-guarded: a failure
    /// callback that arrives after a new run began must not act for the old
    /// run, and the retry must not fire once the run it belonged to is gone
    /// (a new run has a new `liveMirrorSequence.runId`). `started` is the
    /// failed beat's run start, carried through so a late re-send never
    /// stamps a wrong started-at.
    ///
    /// #614 review F5: a TERMINAL failure pre-empts a pending non-terminal
    /// retry (bumping `directRetryToken` invalidates its closure) and bypasses
    /// the consecutive-failure cap via its own budget — the End beat is the
    /// one with no later heartbeat to recover it, so it must never be starved
    /// by a `count` retry that grabbed the single slot first.
    private func directSendFailed(runId: UUID, event: LiveMirrorEvent, started: Date) {
        guard liveMirrorSequence.runId == runId else { return }
        directSendFailures += 1
        directSendConsecutiveFailures += 1
        guard DirectBeatRetryPolicy.shouldRetry(
            event: event,
            consecutiveFailures: directSendConsecutiveFailures,
            retryInFlight: directRetryInFlight,
            endRetries: directSendTerminalRetries
        ) else { return }
        if event.isTerminal { directSendTerminalRetries += 1 }
        directRetryToken &+= 1
        directRetryInFlight = true
        let token = directRetryToken
        let runIdAtSchedule = runId
        let retryEvent = event
        let retryStarted = started
        DispatchQueue.main.asyncAfter(deadline: .now() + DirectBeatRetryPolicy.retryDelayS) {
            [weak self] in
            guard let self else { return }
            // A later (higher-priority) failure superseded this retry — e.g.
            // End pre-empting a pending count retry. It owns the slot now.
            guard self.directRetryToken == token else { return }
            self.directRetryInFlight = false
            guard self.liveMirrorSequence.runId == runIdAtSchedule else { return }
            self.retryDirectBeat(event: retryEvent, started: retryStarted)
        }
    }

    /// Re-send the CURRENT workout state over WatchConnectivity only (the
    /// original beat already went to Supabase). Allocates a fresh monotonic
    /// sequence — a phone that saw the failed beat's sequence still accepts
    /// this one, and terminal dominance on the phone rejects it if the run
    /// already ended there. Direct-only: avoids a duplicate Supabase write.
    ///
    /// #614 round-2 N2: a TERMINAL retry fires even when `liveSync` is
    /// already gone — `end()` tears it down fast when `markEnded()` 401s
    /// (the #472 scenario), which is exactly when the durable fallback also
    /// failed and the direct terminal beat is the last hope. The retry
    /// closure's runId guard still prevents it acting on a newer run, and the
    /// phone's terminal dominance keeps it from resurrecting the ended run.
    private func retryDirectBeat(event: LiveMirrorEvent, started: Date) {
        if !DirectBeatRetryPolicy.mayRetryWithoutLiveSync(event: event) {
            // A non-terminal retry needs the live sync actor — once end() has
            // torn it down there is no live state worth re-sending.
            guard liveSync != nil else { return }
        }
        guard let beat = liveMirrorSequence.nextIfAvailable(event: event) else { return }
        let terminal = beat.terminal
        sendDirectBeat(
            beat: beat, terminal: terminal, started: started,
            hr: terminal ? nil : heartRate,
            count: liveAttempts,
            kcal: terminal ? nil : activeKcal,
            gain: terminal ? 0 : detector.totalElevationGainM,
            climbing: terminal ? false : detector.snapshot.isClimbing,
            cs: terminal ? nil : climbingSince,
            rs: terminal ? nil : restStartedAt,
            rt: terminal ? nil : restTargetS
        )
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
        // #477: stop any further partial flush from starting, unconditionally
        // and before anything else — even in the defensive case where there's
        // no active session below, a leftover in-flight partial must not go
        // on assuming it can still start a coalesced rerun.
        partialFlushSuspended = true

        guard let session, let builder, let startDate else { return nil }

        // #477 review F2: stop the workout FIRST, and only then await the
        // in-flight partial — extracted into its own method (not inlined
        // here) specifically so this ordering is independently testable.
        // Constructing a real HKWorkoutSession/HKLiveWorkoutBuilder is
        // impossible off-device, so `end()` itself can never be driven past
        // the guard above in this test host; `stopRecordingAndAwaitInFlightPartial()`
        // needs neither, so SendLogWatchTests calls it directly. See its doc
        // comment for why the ordering matters: a Timer on the main run loop
        // is NOT paused by a suspended MainActor async function, so awaiting
        // first (the original #477 fix) kept the workout fully live —
        // rawTrace growing, elapsed advancing, detector ticking, the phone
        // mirror still told "live" — for as long as the partial upload took.
        let endDate = await stopRecordingAndAwaitInFlightPartial()

        session.end()
        do {
            try await builder.endCollection(at: endDate)
            try await builder.finishWorkout() // saves the workout to Health
        } catch {
            // Health save failure shouldn't lose the climbing data
            errorMsg = error.localizedDescription
        }

        let attempts = detector.finalize()
        // #481: `hitCap` (SendLogWatchCore's `Attempt.hitCap`, #473) had no
        // consumer — every finalized attempt carried "closed via a duration
        // cap, not a genuine end signal" and nothing ever read it. Same
        // one-shot-per-workout Console breadcrumb as `hrMissingDateInterval`
        // below, not user-facing: a caller was always meant to report this,
        // not silently accept the clamp. #481 review F3: a merge of a capped
        // fragment with a later clean-closing one (< `mergeGapS` apart, same
        // source) keeps only the LAST fragment's `hitCap`
        // (`AttemptDetector.swift`'s merge step, documented there as
        // diagnostic-only) — so this count can under-report a real cap hit
        // that got absorbed into a merged attempt. "at least" says that
        // honestly instead of implying an exact count.
        let cappedAttemptCount = attempts.filter(\.hitCap).count
        if cappedAttemptCount > 0 {
            Self.log.warning("at least \(cappedAttemptCount) attempt(s) this workout closed on a duration cap, not a genuine end signal (#481)")
        }
        // #481 (#477 F4 follow-up): `reportHRMissingDateIntervalOnce()` logs
        // only once per workout, so Console can't tell a single blip from a
        // whole workout of untimestampable readings. The count answers that.
        let missingDateIntervalCount = hrMissingDateIntervalCount
        if missingDateIntervalCount > 0 {
            Self.log.warning("HR quantity delivered with no mostRecentQuantityDateInterval() \(missingDateIntervalCount) time(s) this workout — readings discarded, not trusted (#477/#481)")
        }
        // #614 review F9: the direct WC mirror failures are now observably
        // surfaced (this breadcrumb), and only ever counted on a phone that
        // participates in the acknowledged-send contract (F6) — an old phone
        // build would otherwise make this count lie about link health.
        let directSendFailures = directSendFailures
        if directSendFailures > 0 {
            Self.log.warning("\(directSendFailures) direct WC mirror send(s) failed this workout (#614)")
        }
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

    /// Stops everything that would otherwise keep recording, THEN awaits
    /// whatever partial flush is already in flight. Order matters (#477
    /// review F2): a `Timer` on the main run loop is not paused by a
    /// suspended MainActor `async` function — the main thread just returns
    /// to the run loop while this is parked, so if the await ran first,
    /// `fusionTimer` would keep firing, `rawTrace` would keep growing,
    /// `detector.ingest` would keep running, and `pushBeat()` would keep
    /// telling the phone the workout is "live", all for as long as the
    /// partial upload takes. Tearing down first closes that regardless of
    /// how long the await takes.
    ///
    /// Not `private`: `end()` can only reach this after a guard that needs a
    /// real `HKWorkoutSession`/`HKLiveWorkoutBuilder`, which this test host
    /// cannot construct (no HealthKit entitlement) — so `end()` itself can
    /// never be driven past that guard here. This method needs neither;
    /// SendLogWatchTests calls it directly to prove the ordering.
    func stopRecordingAndAwaitInFlightPartial() async -> Date {
        fusionTimer?.invalidate()
        fusionTimer = nil
        cancelRestAlarm() // no more rest to alarm for once the workout is ending
        altimeter.stopRelativeAltitudeUpdates()
        motion.stopDeviceMotionUpdates()
        // Close the phone's WC mirror immediately. The same terminal beat is
        // queued into the actor-backed Supabase path; the actor waits behind
        // any in-flight telemetry so the durable row cannot be reopened.
        pushBeat(event: .end)
        // Stamped now — before the network wait below, not after it, so a
        // slow partial can no longer inflate the saved duration.
        let endDate = Date()

        // #477: cancelling a detached Task after its request is already on
        // the wire can't stop the server committing it, so this must AWAIT,
        // not cancel. Deliberately UNBOUNDED: supabase-swift does not retry
        // POSTs (`PostgrestBuilder.retryableMethods` excludes `.post`) and
        // times a single request out at 60s on its own
        // (`HTTPRequest`'s per-request timeout) — that third-party default
        // is the real bound on how long this can park, not something this
        // function imposes. A shorter, self-imposed timeout here would
        // reopen the exact bug #477 closes: an abandoned-but-still-in-flight
        // partial could still land on the server after the final row this
        // method's caller is about to write, with nothing left holding it
        // back. The workout itself is already fully torn down above by the
        // time this suspends, so the only user-visible cost of the 60s is
        // the End button staying disabled that long, not stale/growing data.
        if let partialFlushTask {
            _ = await partialFlushTask.value
        }
        partialFlushTask = nil
        return endDate
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
                tunables: .default,
                // #529: the account captured at start(), not whoever is
                // signed in now — `end()` may run long after an account
                // switch mid-workout. `ownerUserId` is nil only when the run
                // started with nobody signed in at all (unreachable via the
                // UI today — RootView gates Start behind a relayed sign-in);
                // in that one case there is no captured owner to preserve,
                // so this falls back to reading the live signed-in account
                // right now — an explicit, documented decision (#529 F5),
                // not a silent nil sailing into the legacy queue fallback.
                ownerUserId: ownerUserId ?? userIdProvider()
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
            // #529 F3: `pendingCount()` deliberately excludes an item held
            // for a DIFFERENT account than the one currently signed in
            // (#158/#189) — reading that as `stillQueued == false` here
            // would render the "uploaded" copy for a bundle that hasn't
            // gone anywhere. Ask the honest, bundle-specific question
            // instead of the account-wide count.
            if shouldDrain(itemUserId: bundle.enqueuedUserId, currentUserId: userIdProvider()) {
                stillQueued = await OfflineQueue.shared.pendingCount() > 0
                stillQueuedForAnotherAccount = false
            } else {
                stillQueued = true
                stillQueuedForAnotherAccount = true
            }
        } else {
            stillQueued = false
            stillQueuedForAnotherAccount = false
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

    /// Not `private`: SendLogWatchTests calls this directly to prove it only
    /// logs once per workout (#477 review F4) — Console/os_log output isn't
    /// otherwise observable from a unit test.
    func reportHRMissingDateIntervalOnce() {
        hrMissingDateIntervalCount += 1
        guard !hrMissingDateIntervalLogged else { return }
        hrMissingDateIntervalLogged = true
        Self.log.warning("HR quantity delivered with no mostRecentQuantityDateInterval() — reading discarded, not trusted (#477)")
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
            pushBeat(event: .phase)
        }
        // #476: liveAttemptCount can cross AttemptDetector's post-filter
        // threshold mid-attempt with no phase transition (see
        // WidgetCountSync's doc comment) — pushing only on `stateChanged`
        // left the widget's boulder count stuck until the attempt ended.
        if WidgetCountSync.shouldPush(stateChanged: stateChanged, countBefore: countBefore, countAfter: countAfter) {
            // Sensor fusion callbacks are not actor-isolated. Hop to the
            // widget bridge's main-actor gate so sign-out/new-refresh
            // ownership is checked on the same executor as its store write.
            let phaseSince = after.isClimbing ? climbingSince : restStartedAt
            let climbing = after.isClimbing
            let target = restTargetS
            Task { @MainActor in
                WidgetBridge.updateLiveWorkout(
                    active: true, boulders: countAfter,
                    climbing: climbing,
                    phaseSince: phaseSince,
                    restTargetS: target
                )
            }
            if !stateChanged { pushBeat(event: .count) }
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
        // #529 F1: this periodic upsert had no notion of ownership at all —
        // unlike the end-of-run bundle (held via `shouldDrain` once it's on
        // the queue), a flush that fires AFTER an A → signed-out/B
        // transition would otherwise write A's in-progress `climb_workouts`
        // row straight to the network under B's currently-relayed token,
        // landing A's elevation/attempt data in B's account — and can also
        // permanently strand A's later held save, since the row would then
        // exist owned by B and A's eventual upsert would be refused by RLS.
        // Best-effort by design (SL-90): skipping here loses nothing
        // durable — the next flush (or the final `endAndSave()`, which DOES
        // carry the immutable `ownerUserId`) picks the snapshot up once the
        // real owner is active again.
        guard userIdProvider() == ownerUserId else { return }
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
            // Nothing to snapshot. #477 review F3: `completePass()`'s return
            // value must not be discarded here — if something else was
            // requested (`.rerun`) while this "pass" was `running` with no
            // `startDate` to act on, dropping it wedges the drain `running`
            // forever with nothing left to un-stick it, and every later
            // `flushPartial()` call silently returns `.queued` and does
            // nothing for the rest of the workout. Not reachable today (the
            // only production caller already guards `startDate` before
            // calling `flushPartial()`), but loop rather than leave a latent
            // "durable flushing silently dead" trap.
            if partialFlushDrain.completePass() == .rerun {
                runPartialFlush()
            }
            return
        }
        // #477 review F3/R1: stamp this flush with the CURRENT
        // `partialFlushEpoch` — this manager is App-scoped and long-lived
        // (#476A), so by the time this flush's network call resolves, a new
        // ACCEPTED `start()` may already have installed a fresh
        // `partialFlushDrain` for a DIFFERENT workout. Deliberately NOT
        // `startGuard.generation`: that counter bumps on every `start()`
        // call `begin()` lets past its concurrency check, INCLUDING one
        // later rejected by `guard !isRunning else { return }` — a rejected
        // call runs nothing past that guard, so the drain is NOT replaced,
        // but `startGuard.generation` has already moved on regardless
        // (R1 — verified: it silently wedges the drain `running` forever
        // with no rejected-start test to catch it). `partialFlushEpoch` only
        // ever advances in the SAME block that replaces the drain, so it can
        // only ever say "still current" while the drain this flush was
        // created against is still the live one.
        let epoch = partialFlushEpoch
        let partial = ClimbWorkoutPartialUpsert(
            id: workoutId,
            startedAt: startDate,
            endedAt: Date(),
            elevationGainM: detector.totalElevationGainM,
            attemptsDetected: liveAttempts,
            attemptsConfirmed: liveAttempts,
            raw: tunables.keepRawTrace ? rawTrace : nil,
            // #529 F1/F6: defense-in-depth behind the `flushPartial()` guard
            // above — if the active account changes DURING this call's
            // network round trip (the guard only checks before dispatching),
            // an explicit, wrong `user_id` makes Postgres's `with check
            // (auth.uid() = user_id)` refuse the write instead of silently
            // accepting it under whoever is relayed when the request lands.
            userId: ownerUserId
        )
        let uploader = partialUploader
        let task = Task.detached(priority: .background) {
            await uploader(partial)
        }
        partialFlushTask = task
        Task { @MainActor [weak self] in
            _ = await task.value
            guard let self else { return }
            guard self.partialFlushEpoch == epoch else {
                // An ACCEPTED start() has begun since this flush was
                // created — the SAME reset block that bumps this epoch also
                // installed a fresh CoalescingDrain and reset
                // partialFlushTask/partialFlushSuspended for the workout
                // that's running now, so "the epoch moved" and "the drain
                // was replaced" can never disagree (unlike
                // startGuard.generation, which bumps on every start() call
                // begin() lets through — including one immediately rejected
                // by `guard !isRunning`, which replaces nothing — see R1).
                // Touching either here would be this stale closure deciding
                // workout N+1's state (the exact #476A hazard this manager
                // was hoisted to remove), and `completePass()` on a drain
                // this handler never `.request()`-ed against hits its own
                // precondition.
                return
            }
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
                // #529 slice-2 review R1: `flushPartial()`'s own ownership
                // guard only protects the request that arrives WHILE this
                // one is already in flight — the account can just as well
                // change during the network round trip itself, and this
                // coalesced rerun calls `runPartialFlush()` directly,
                // bypassing that guard entirely. Re-check here too, or an
                // A → signed-out/B transition mid-flight lets one more
                // partial upsert fire under B's currently-relayed token
                // after `flushPartial()` would have refused a fresh call.
                guard self.userIdProvider() == self.ownerUserId else {
                    // #529 slice-2 review F3: `completePass()` above already
                    // consumed the rerun request but left `running == true`
                    // (its contract: a `.rerun` caller is expected to
                    // actually perform another pass and complete THAT one
                    // too). Declining to run without resolving the drain
                    // wedges it `running` forever — every later
                    // `flushPartial()` on this still-live workout would hit
                    // `.request()` → `.queued` and do nothing, exactly the
                    // "durable flushing silently dead for the rest of the
                    // workout" hazard `partialFlushEpoch`'s own doc comment
                    // warns about 80 lines up, just reached from an ownership
                    // mismatch instead of a stale epoch. A second
                    // `completePass()` call here sees `requestedAgain ==
                    // false` (already cleared above) and returns `.idle`,
                    // clearing `running` — safe to call synchronously with no
                    // intervening `await`, so nothing else can have re-armed
                    // `requestedAgain` in between.
                    _ = self.partialFlushDrain.completePass()
                    return
                }
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
            // #480 review F1: `session.delegate = nil` in start()'s catch
            // closes the common case, but isn't documented to cancel a
            // callback already dispatched before that assignment lands —
            // this identity check is the real backstop against a dead
            // session (one whose beginCollection failed) painting its error
            // over whatever workout is actually running by the time this
            // Task resumes on MainActor.
            guard workoutSession === self.session else { return }
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
        var hrMissingDateInterval = false
        for type in collectedTypes {
            guard let quantityType = type as? HKQuantityType,
                  let stats = workoutBuilder.statistics(for: quantityType) else { continue }
            switch quantityType {
            case HKQuantityType(.heartRate):
                // #477: the SAMPLE time HealthKit reports this reading as
                // covering — not `Date()`, which would measure when this
                // callback happened to be delivered, not sensor age.
                if let value = stats.mostRecentQuantity()?.doubleValue(for: .count().unitDivided(by: .minute())) {
                    if let sampleAt = stats.mostRecentQuantityDateInterval()?.end {
                        hrCandidate = HeartRateSample(value: value, sampleAt: sampleAt)
                    } else {
                        // #477 review F4: a real quantity with no interval to
                        // stamp it — can't accept it (nothing to check
                        // monotonicity/staleness against), so this stays
                        // "absent" like a genuine sensor gap, not "trust it
                        // anyway". See `hrMissingDateIntervalLogged`'s doc
                        // comment for why this is reported rather than fully
                        // silent.
                        hrMissingDateInterval = true
                    }
                }
            case HKQuantityType(.activeEnergyBurned):
                kcalCandidate = stats.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
            default:
                break
            }
        }
        Task { @MainActor in
            // #480 review F2: same backstop as `didFailWithError` above —
            // a discarded builder (beginCollection failed inside start())
            // has its delegate nil'd in the catch, but an already-dispatched
            // callback isn't guaranteed cancelled by that, so this identity
            // check is what actually stops it clobbering `activeKcal`/HR for
            // whatever workout N+1 is live by the time this Task runs.
            guard workoutBuilder === self.builder else { return }
            if let hrCandidate {
                self.acceptHeartRate(hrCandidate)
            }
            if hrMissingDateInterval {
                self.reportHRMissingDateIntervalOnce()
            }
            if let kcalCandidate {
                self.activeKcal = kcalCandidate
            }
        }
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
