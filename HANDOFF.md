# HANDOFF — #476 Part A: watch workout ownership + navigation

Scope: Part A only (hoist `WorkoutManager`, guard navigation, timer/double-start
hygiene, widget count sync). Part B (`recoverActiveWorkoutSession`, detector
checkpoint) is explicitly **not** touched. `OfflineQueue.swift`, `Repo.swift`,
`AttemptDetector.swift` are **not** touched (per the sibling-branch note) — see
"Things I did NOT touch" below for the one place I was tempted to.

## What changed and why

### 1. Hoisted `WorkoutManager` to App scope (`SendLogWatchApp.swift`)

`WorkoutManager` used to be `@State private var workout = WorkoutManager()`
inside `WorkoutLiveView`, a `navigationDestination` — the asymmetry with
`TindeqManager` (already App-scoped) was the bug. Now:

- `SendLogWatchApp` owns `@State private var workout = WorkoutManager()` and
  injects it via `.environment(workout)`, same as `tindeq`.
- `WorkoutLiveView` and `RootView` both read it via
  `@Environment(WorkoutManager.self)` instead of owning their own copy.
- The `#Preview` blocks in `WorkoutLiveView.swift` now inject a posed manager
  via `.environment(...)` instead of the removed `init(previewWorkout:)`.

This fixes **both** destruction paths named in the issue:
- A Force/status complication `open(_:)` replacing the NavigationStack path —
  the manager isn't owned by the popped view any more, so it isn't destroyed.
- `RootView.body` switching on `auth.state` (a `signedOut` relay mid-workout
  swaps the whole `NavigationStack` for `WaitingForPhoneView`) — the manager
  lives *above* that switch (in `SendLogWatchApp`), so it's unaffected by
  which branch `RootView.body` renders.

### 2. Hoisted the save path with it

`endAndSave()`, `retryFailedSave()`, the private `save(_:)`, and the
`ending`/`justSaved`/`stillQueued`/`failedBundle` state all moved from
`WorkoutLiveView` into `WorkoutManager`. `failedBundle` (#287's in-memory last
copy of a workout whose disk write *and* direct upload both failed) used to be
`@State` on the view — if the view was torn down mid-save, the save's
completion wrote into detached state nobody could read again. It's now
observable on the shared manager, so a freshly (re)created `WorkoutLiveView`
picks up the real outcome. The rest-alarm haptic Task (`restAlarmTask`/
`cancelRestAlarm()`) stayed view-local on purpose — it's a UI-only timer with
no data-loss risk if it's dropped, and hoisting it would have meant giving
`WorkoutManager` a `WKInterfaceDevice` haptic-scheduling responsibility that
belongs to the view.

### 3. Navigation guard — `WatchNavigation.resolvedPath` (Core) + `RootView.open(_:)`

New pure resolver in `SendLogWatchCore/WatchNavigation.swift`
(`WatchDest`/`WatchDeepLinkHost` also moved there from `RootView.swift`):

- `.force` while a workout is running → path `[.workout, .force]` (the
  running workout, and its End button, stay one back-tap away instead of
  being popped off screen entirely).
- `.workout` → always `[.workout]` (unchanged).
- `.status` → always `[]` (the stack root) — a status complication is
  supposed to jump to the status glance; the workout stays reachable from
  Home's "Climb Workout" link, which now also shows an orange hint
  ("Workout running — tap Climb Workout to end it") when
  `workout.isRunning`, added to `ActionsView` in `HomeView.swift`.

`RootView.open(_:)` is now a 4-line pass-through to this resolver with no
independent routing logic of its own — see "What I could not verify" for why
I stopped there instead of driving the real NavigationStack in a test.

### 4. Double-Start guard + cachedPhase generation stamp — `WorkoutStartGuard` (Core)

New `WorkoutStartGuard` struct in `SendLogWatchCore/WorkoutLifecycle.swift`:
`begin()` (synchronous, before any `await`) rejects a concurrent call and
mints a generation stamp; `finish()` releases it; `isCurrent(_:)` tells stale
async work from a since-superseded start apart from the current one.
`WorkoutManager.start()` now does:

```swift
guard let generation = startGuard.begin() else { return }
defer { startGuard.finish() }
```

as its first two lines, and the background `cachedPhase` fetch Task checks
`startGuard.isCurrent(generation)` before writing back — relevant post-hoist
because the manager now outlives any single workout, so a slow fetch from a
workout that already ended must not stomp the next workout's `cachedPhase`.

### 5. `deinit` invalidates `fusionTimer`

`end()` already invalidated it; `deinit` didn't, so any deallocation path that
skipped `end()` left the timer registered on the run loop (which retains it),
firing forever into an already-nil `[weak self]`. One-line fix.

### 6. Widget count sync — `WidgetCountSync.shouldPush` (Core)

`AttemptDetector.liveAttemptCount` re-applies the post-filter (min duration +
min active-motion ticks) on every read, so it can cross from 0→1 **mid-climb**
with `snapshot.state` staying `.autoClimbing` throughout (no phase
transition). `startFusion()` used to push `WidgetBridge.updateLiveWorkout`
only on a state change; now it also pushes when the count itself changed
(`WidgetCountSync.shouldPush(stateChanged:countBefore:countAfter:)`).

## Acceptance criteria — status and how each was verified

1. **Deep-link test must use `sendmeter://force` or `sendmeter://status`;
   assert workout ID/start date survive, beats continue, End stays
   reachable.**
   - **Core-level, `swift test`, verified to fail pre-fix (see below):**
     `WatchNavigationTests` in `WorkoutLifecycleTests.swift` proves the
     resolver keeps `.workout` in the path for `.force` while running, and
     `RootView.open(_:)` is a direct, logic-free pass-through to it (code
     inspection).
   - **App-level, run on a booted watchOS Simulator, verified to fail
     pre-fix (see below):** `WorkoutOwnershipTests` (`SendLogWatchTests`)
     Mirror-inspects `WorkoutLiveView` and `RootView` and asserts their
     `workout` property is `Environment<WorkoutManager>`, not
     `State<WorkoutManager>`. This is the direct proof for "ID and start
     date survive": with a single App-scoped instance there is nothing to
     regenerate — a `@State`-owned manager, by contrast, gets a fresh
     `workoutId = UUID()` and `startDate = nil` every time its owning view
     is recreated, which is exactly the pre-fix failure mode both tests
     reproduce (see below).
   - **NOT verified: driving an actual `NavigationStack` through a real
     `sendmeter://force` `.onOpenURL` call and confirming the rendered
     screen sequence / back-button behavior.** This test host has no
     ViewInspector-equivalent and XCUITest wasn't in scope for a unit test
     addition — see the manual/device matrix below.

2. **Double Start reaches exactly one HealthKit setup and one timer.**
   - **Core-level, `swift test`:** `WorkoutStartGuardTests` proves the guard
     itself: a second `begin()` while the first is in flight returns `nil`.
   - **App-level, run on Simulator:** `WorkoutManagerDoubleStartTests
     .testConcurrentDoubleStartIsAcceptedExactlyOnce` calls
     `manager.start()` twice concurrently via `async let` and asserts
     `manager.acceptedStartCount == 1`. I could **not** assert on
     `fusionTimer`/an actual second HealthKit call directly: this test host
     has no HealthKit entitlement, so `requestAuthorization()` reliably
     throws before `startFusion()` would ever run — confirmed in the actual
     simulator run log (`FAILED prompting authorization request ... Missing
     com.apple.developer.healthkit entitlement`), on *both* the pre-fix and
     post-fix code, so a `fusionTimer`-based assertion would pass either way
     and prove nothing. `acceptedStartCount` is the guard's own generation
     counter, exposed for this purpose — it's incremented at the exact same
     point that gates `startFusion()`, so "exactly one accepted" and
     "exactly one HealthKit-setup/timer attempt" are the same claim as far
     as this code path is concerned, but the HK/timer act itself is
     device/simulator-with-entitlement-only to observe directly.

3. **`fusionTimer` is nil after `deinit`.**
   - **App-level, run on Simulator:** `WorkoutManagerDeinitTests
     .testFusionTimerIsInvalidatedWhenTheManagerDeinits` calls
     `startFusion()` directly (loosened from `private` to internal for
     testability, alongside `fusionTimer` itself), captures the `Timer`,
     drops the manager, and asserts `timer.isValid == false` — `isValid`
     is the closest a `Timer` reference lets you observe "was invalidated"
     after the object holding it is gone. Passed.

4. **A `signedOut` relay mid-workout does not destroy the workout.**
   - Same mechanism and same test as #1's Mirror check on `RootView`:
     `RootView.body` is exactly the view that branches on `auth.state`, and
     `testRootViewReadsWorkoutManagerFromEnvironmentNotState` proves
     `RootView` doesn't shadow the App-scoped manager with a view-local
     copy that would be destroyed by that branch swapping which subtree is
     mounted.
   - **NOT verified: an actual `auth.state` transition to `.signedOut` while
     a real `HKWorkoutSession` is live, confirmed via device/simulator
     observation that the workout screen, once back, still shows the same
     running state.** Structural proof only — see the matrix below.

### Proof these tests fail on pre-fix code (not passing by construction)

Per the house rule, I didn't just add new tests and declare them proof — I
stashed the five production-code changes (keeping the new test file, the new
Core files, and the pbxproj registration) and reran the ownership tests
against the **unmodified** `WorkoutLiveView.swift`/`RootView.swift` on the
same booted simulator:

```
testRootViewReadsWorkoutManagerFromEnvironmentNotState: failed
  - expected RootView to declare a `workout` property
testWorkoutLiveViewReadsWorkoutManagerFromEnvironmentNotState: failed
  - XCTAssertTrue failed - WorkoutLiveView.workout must be @Environment-sourced
    (found State<WorkoutManager>)
```

Both fail for exactly the reason the fix addresses (old `RootView` never
referenced a workout manager at all; old `WorkoutLiveView` owned one as
`State<WorkoutManager>`). `WorkoutManagerDoubleStartTests` and
`WorkoutManagerDeinitTests` reference `acceptedStartCount`/non-private
`fusionTimer`/`startFusion()`, none of which exist on pre-fix
`WorkoutManager` — they fail to **compile** against old code, which is a
stronger form of "fails on current code." All changes were then restored
(`git stash pop`) and the full suite re-verified green (below).

## Validation run

- `cd ios/App/SendLogWatchCore && swift test` — **213/213 passed**, including
  the 12 new tests (`WorkoutStartGuardTests` ×4, `WidgetCountSyncTests` ×3,
  `WatchNavigationTests` ×4, plus
  `AttemptDetectorTests.testLiveAttemptCountCanChangeWithoutStateTransition`,
  which directly demonstrates the widget-count bug at the detector level:
  count goes 0→1 at tick 38 while `snapshot.state` is `.autoClimbing` at both
  tick 37 and 38 — no transition to key a push off of).
- `xcodebuild build -project ios/App/App.xcodeproj -scheme "SendLogWatch Watch App" -destination "generic/platform=watchOS Simulator" CODE_SIGNING_ALLOWED=NO`
  — **BUILD SUCCEEDED** (one fixup needed: `HomeView.swift` was missing
  `import SendLogWatchCore` once `WatchDest` moved there — fixed).
- `xcodebuild test -destination "id=<Apple Watch Series 11 (42mm) sim>" -only-testing:SendLogWatchTests` (whole target, not just the new file) —
  **115/115 passed**, confirming the new tests coexist cleanly with the
  existing hosted suite (`PendingQueue*`, `RPEModelTests`,
  `WorkoutSaveBundleDecodeCompatTests`, etc.) and nothing else regressed.
  This test target needs `TEST_HOST` (a launched app), so it isn't part of
  `ios-ci.yml`'s `swift` job (build-only, per CLAUDE.md) — it only ran here
  because a watchOS simulator happened to be available in this environment;
  don't assume it runs in CI.
- Web: not touched, `npm run typecheck/lint/test/build` not applicable.

## Things I could NOT verify from here (manual/device matrix)

| Scenario | Why untestable here | How to check |
|---|---|---|
| Tapping the Force complication mid-workout actually renders WorkoutLiveView→ForceGaugeView with a working back button that reaches a live End control | No ViewInspector/XCUITest in this pass; NavigationStack rendering needs a live app | Install to a paired iPhone+watch sim (or device), start a workout, background, tap the Force complication (or `xcrun simctl openurl booted sendmeter://force`), confirm back-nav reaches End and the workout is still counting |
| Same for the status complication (`sendmeter://status`) | Same | `xcrun simctl openurl booted sendmeter://status` mid-workout; confirm the "Workout running — tap Climb Workout to end it" hint shows on the Actions page and leads back to a live End |
| A real `signedOut` WatchConnectivity relay arriving mid-workout, observed end-to-end (not just the ownership-model proof) | Needs a live HKWorkoutSession + a real auth relay; this test host has no HK entitlement | Paired sims: start a workout, sign the phone out (or force the relay), confirm the watch's `WaitingForPhoneView` doesn't kill the session, then re-sign-in and confirm the workout screen still shows the running state and End works |
| A real double-tap on Start reaching HealthKit exactly once — i.e., confirming a *second* HealthKit permission prompt never appears, and only one fusion timer is measurably ticking | No HK entitlement in this test host (see criterion #2 above) | On-device/simulator-with-entitlement: rapidly double-tap Start, confirm one auth prompt (first launch) and no duplicate/faster-than-expected `elapsed` ticking |
| Widget count actually updates mid-attempt on a real Smart Stack/complication | WidgetKit extension + App Group, simulator gallery doesn't run complications | Device-only per CLAUDE.md's existing note on this area |
| `failedBundle` surviving a real save failure across a torn-down/recreated `WorkoutLiveView` (not just the ownership-model proof) | Needs a live save-path failure (network down) plus real navigation | Airplane-mode the watch mid-End, confirm "Workout not saved"/Retry survives a Force complication tap and back |

## Things I did NOT touch

- `OfflineQueue.swift`, `Repo.swift`, `AttemptDetector.swift` — untouched, as
  instructed (sibling #475 branch). `WorkoutManager.endAndSave()`/`save(_:)`
  call `OfflineQueue.shared.enqueue(...)` / `.pendingCount()` exactly as the
  old `WorkoutLiveView` code did — no new call shape, no seam needed for this
  branch's scope.
- No `recoverActiveWorkoutSession`, no detector checkpoint — Part B, out of
  scope per the issue comment.
- Did not add a fixed-refractory or detector-behavior change — out of scope
  (that's #473/PR 6 per the plan).

## Things I'm unsure about / worth a second look

- **Product decision, not just a bug fix:** the `.force`-while-running path
  now injects `.workout` as a base, so tapping the Force complication
  mid-workout shows WorkoutLiveView first with a back button to Force,
  rather than jumping straight to Force. I judged this the more defensible
  reading of "End stays reachable," but it does change what a Force
  complication tap shows compared to today. Flagging in case the intended
  behavior was "go straight to Force, but leave a way back" via a different
  mechanism (e.g. a persistent banner) instead.
- **`acceptedStartCount`** is a small test-only surface addition to
  `WorkoutManager` (exposes the guard's internal generation count). It's the
  only way I found to assert on the double-start guard's effect on the
  *production* `start()` method without a HealthKit entitlement in this test
  host — flagging in case a reviewer would rather this be asserted some other
  way (or not exposed at all, relying solely on the Core-level
  `WorkoutStartGuardTests`).
- The `pbxproj` diff includes an incidental reordering of two unrelated
  `XCSwiftPackageProductDependency` entries (SendLogWatchCore/Supabase) — a
  side effect of the `xcodeproj` gem's save/re-serialize, not an intentional
  change. Confirmed `plutil -lint` passes and the project builds/tests clean;
  called out here so it isn't mistaken for something else in review.
