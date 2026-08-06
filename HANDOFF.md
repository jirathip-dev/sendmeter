# HANDOFF — #476 Part A: watch workout ownership + navigation

Scope: Part A only (hoist `WorkoutManager`, guard navigation, timer/double-start
hygiene, widget count sync). Part B (`recoverActiveWorkoutSession`, detector
checkpoint) is explicitly **not** touched. `OfflineQueue.swift`, `Repo.swift`,
`AttemptDetector.swift` are **not** touched.

**This revision responds to `REVIEW.md`'s CHANGES-REQUESTED verdict on commit
`85764b3`.** That review found the hoist itself was correct (and re-verified
the ownership tests independently) but had re-created the class of bug #476
exists to fix, through a new route: the save-outcome state the hoist carried
over (`failedBundle`, `justSaved`) was never reset by `start()` and was
checked *before* `isRunning` in the view, so a save outcome from workout N
could cover a running workout N+1 with no End control, and a `.lost`
`failedBundle` could lock Start out for the rest of the app session. This
document covers the original work plus every finding (F1–F8) from that
review.

**Second review round: APPROVE, with three non-blocking findings (R1–R3).**
All eight F1–F8 fixes were independently re-verified and confirmed; F1's
restructure held up against both original scenarios. R1 and R2 were each
one-liners that re-created the bug class #476 exists to fix through a new
route, exposed precisely *because* the F1 fix correctly unblocked Start — so
they're covered here too, along with R3's two accuracy defects. Issue #480 is
now filed for the pre-existing `startActivity`/`beginCollection` orphan
hazard (first surfaced as a side note in the first review's F7); it is
explicitly **not** fixed in this branch, per instruction.

**Third review round (final pass on `5bc2fa9`): APPROVE**, with two findings
in test code (X1, X2 — nothing in shipped behavior) that the user then
overruled from non-blocking to blocking. **Both are fixed in this revision,
and this correction is important: the previous version of this document
claimed "120/120 passed" as a settled fact. It was not.** The reviewer ran the
same target five times on the unmodified commit and got two outright failures
and three clean passes — a ~60%-of-the-time fact, not a 100%-of-the-time one.
The root cause (X1) and a second instance of this branch's recurring habit —
a comment claiming a test enforces something it doesn't (X2) — are both
addressed below, with the corrected, actually-repeated pass rate reported
where the false claim used to be.

## Findings from REVIEW.md, round 3 (X1, X2) — now blocking, both fixed

### X1 — the R1 regression tests were intermittently failing and ~160× slower than the rest of the suite

**This was real, not a one-off.** The reviewer ran `SendLogWatchTests` five
times on unmodified `5bc2fa9`: runs 1 and 2 **failed**, runs 3–5 passed
120/120. Root cause: `testSuccessfulSaveDoesNotClearAnUnrelatedFailedBundle`
and `testSuccessfulSaveClearsItsOwnMatchingFailedBundle` drove the real
`WorkoutManager.save()`, which reaches `OfflineQueue.enqueue` (real disk I/O,
uncleaned `pending/<uuid>.json` files left behind) and
`WidgetBridge.refreshStatus()` (real network calls against
`http://127.0.0.1:54321`, retried with backoff — ~15.9s per test, all logged
as `NSURLErrorDomain Code=-1004`). The previous handoff reported "120/120
passed" from a single run and did not disclose this — that is exactly the
failure mode this entire branch exists to eliminate: a green run that doesn't
mean what it claims to mean, in the only automated coverage `WorkoutManager`
has.

**Fix — the Core-helper refactor from `REVIEW.md` section 5, which is also
its ruling on the `internal save()` question:**
- Added `FailedBundleClear.shouldClear(failedId:savedId:)` to
  `SendLogWatchCore/WorkoutLifecycle.swift` — the pure id-comparison R1
  needs, with no dependency on `OfflineQueue`/`WidgetBridge`/network.
- Tested in `SendLogWatchCoreTests/WorkoutLifecycleTests.swift`
  (`FailedBundleClearTests`, 3 tests, microseconds, runs via `swift test` —
  CI-covered by `ios-ci.yml`'s `package-tests` job, unlike `SendLogWatchTests`
  which needs a `TEST_HOST` and isn't in CI at all per CLAUDE.md).
- `WorkoutManager.save()` reverted to `private` (its widening was the
  reviewer's diagnosed cost, not a production hazard on its own — but nothing
  needs it exposed once the invariant is tested in Core) and now calls
  `FailedBundleClear.shouldClear(...)` — its one production call site,
  verified by inspection.
- Removed the two flaky/slow tests from `WorkoutSavePathResetTests.swift`,
  replaced with a comment pointing at where the invariant is actually tested
  now and why.

**Result, verified by actually re-running it — not by asserting it works:**
ran the full `SendLogWatchTests` target **five consecutive times** on this
fix. All five: **118/118 passed, `** TEST SUCCEEDED **`**, each run
completing in **well under a second** (0.23s–0.75s total test time, per the
`xcodebuild` summary line) with zero network log output. Compare: the
pre-fix suite took ~32s per run and failed 2 of 5 times. Full output of all
five runs is reproducible via:
```
for i in 1 2 3 4 5; do
  xcodebuild test -project ios/App/App.xcodeproj -scheme "SendLogWatch Watch App" \
    -destination "id=<sim udid>" -only-testing:SendLogWatchTests CODE_SIGNING_ALLOWED=NO
done
```
(118 = 120 from the previous count, minus the 2 removed flaky tests.)

### X2 — a third instance of a comment claiming coverage that doesn't exist

The comment on `WorkoutOwnershipTests.testFailedBundleNeverGatesTheScreen`
claimed that a regression restoring
`if workout.failedBundle != nil { failedSaveContent }` ahead of the switch in
`WorkoutLiveView.body` "fails this test, as long as `body` keeps calling this
seam" — a hedge that was doing all the work and stating exactly the untested
assumption. **I verified this myself before touching the comment**, per the
standing instruction to verify claims by breaking the thing: temporarily
wrapped `body`'s switch in exactly that gate
(`if workout.failedBundle != nil { startContent } else { switch
Self.screen(for: workout) { … } }`), ran
`-only-testing:SendLogWatchTests/WorkoutOwnershipTests`, and got
**`testFailedBundleNeverGatesTheScreen` passing, 3/3 `** TEST SUCCEEDED **`**
— confirming the reviewer's finding exactly. Reverted the probe; tree clean
before the real fix.

**Fix:** rewrote the comment to state only what's actually enforced — the
decision function itself and what `body` currently switches on — and to name
the gap explicitly: a regression that wraps the whole switch in a *new*
`if failedBundle != nil` check, bypassing `screen(for:)` entirely rather than
changing what it returns, is not caught, because nothing in this test suite
reads what `body` actually renders (no ViewInspector / hosting-controller seam
exists in this project). This is the third instance of the same pattern on
this branch (round 1's F1, round 2's R3a, now this) — the standing rule going
forward, restated in code as well as in this document: **a test comment may
only claim what has been verified by actually breaking the thing and watching
the test fail; if you can't make it fail, say what IS enforced, not what you
intended.**

## Findings from REVIEW.md, round 2 (R1–R3)

### R1 (MEDIUM) — `save()`'s success path cleared ANY `failedBundle`, not just its own

`WorkoutManager.swift`, in `save(_:)`'s success path: `failedBundle = nil` ran
unconditionally on every successful save. This was unreachable before F1 (a
failed save blocked Start entirely), but F1 correctly made Start reachable
again — which means this scenario is now real: workout N fails `.lost`
(`failedBundle = bundleN`), the user taps **Start** instead of **Retry**,
climbs workout N+1, N+1 saves successfully, and the old code silently
discarded `bundleN` while rendering "Saved" — CLAUDE.md #264 is explicit that
unsaved training data must be reported, never swallowed, and `failedBundle`
has no separate reporting path at all.

**Fix:** narrowed to an id match, exactly as the review's suggested minimal
fix:
```swift
if failedBundle?.workout.id == bundle.workout.id {
    failedBundle = nil
}
```
An unrelated failed bundle now survives a different workout's successful
save; a bundle's own (re)save — e.g. via Retry — still clears it.

**Regression tests**, both against the real `save()` (loosened from `private`
to internal for this — same pattern as `startFusion()`/`fusionTimer`):
- `testSuccessfulSaveDoesNotClearAnUnrelatedFailedBundle` — sets a stale
  `failedBundle`, calls `save()` with a *different* bundle, asserts the stale
  one survives.
- `testSuccessfulSaveClearsItsOwnMatchingFailedBundle` — same bundle,
  asserts it's cleared.
- **Verified to fail on the pre-R1 commit (`47e52e3`)**: stashed just
  `WorkoutManager.swift` back to that commit and reran — both new tests
  **failed to compile** (`'save' is inaccessible due to 'private' protection
  level`), since `save()` wasn't yet exposed there. Restored and reconfirmed
  the full suite green.

### R2 (LOW) — `start()` entered while already running could orphan the live session

`WorkoutManager.swift`, `start()`'s reset block: F7's own fix (nil-ing
`session`/`builder`/`startDate`/`liveSync` unconditionally at the top of
`start()`) opened a new hole the review owns as a consequence of its own ask.
If `start()` were ever entered while `isRunning` is already `true` and then
threw (e.g. `requestAuthorization()` failing), the reset block would nil the
*live* workout's `session`/`builder`/`startDate` before the throw — orphaning
that `HKWorkoutSession` with no handle left to end it. `isRunning` stays
`true`, `WorkoutScreenSelection` keeps returning `.live`, and `end()`'s
`guard let session, let builder, let startDate else { return nil }` silently
does nothing. That's the exact shape of the bug #476 exists to fix.

**Fix:** added `guard !isRunning else { return }` immediately after the
existing double-tap guard (`startGuard.begin()`/`defer { startGuard.finish()
}`), so it's covered by the same `defer` and refuses re-entry over an
already-running workout, not just concurrent double-taps.

Not independently regression-tested: reaching this path requires a caller to
invoke `start()` while `isRunning` is already `true`, which nothing in the
current UI does (the guard closes a *latent* exposure the F7 fix introduced,
same as F7 itself was latent) — there's no existing reachable path to drive
a test through it without fabricating a call site that doesn't otherwise
exist. The fix is a direct, low-risk one-line addition matching the guard
pattern already used and tested one line above it (`WorkoutStartGuardTests`
covers the concurrent-call half of this same guard mechanism).

### R3 (LOW) — two accuracy defects

**(a) A comment cited a test that didn't exist**, and the invariant it
described had no real coverage. `WorkoutScreenSelectionTests.swift` referenced
`WorkoutLiveViewFailedBundlePlacementTests`, which was never written anywhere
in the tree — meaning rule 2 of `WorkoutScreenSelection`'s doc ("a failed
save can never block Start") was enforced only by *where* `failedSaveBanner`
happens to sit inside `startContent`, with no test pinning it. A future edit
re-adding `if workout.failedBundle != nil { failedSaveContent }` ahead of the
switch in `WorkoutLiveView.body` would reinstate F1's scenario B (Start
locked out) with every existing test green.

**Fixed with a real seam, not just a comment deletion** — `@Environment`
can't be resolved outside a hosted view, so a test can't construct a
`WorkoutLiveView` and read its `body` directly (the same tooling gap noted
throughout this branch). Added `WorkoutLiveView.screen(for:)`, a `static`
function taking the manager explicitly:
```swift
static func screen(for workout: WorkoutManager) -> WorkoutScreen {
    WorkoutScreenSelection.screen(isRunning: workout.isRunning, justSaved: workout.justSaved)
}
```
`body` now calls `Self.screen(for: workout)` — this is the exact function it
switches on, not a parallel copy. `WorkoutOwnershipTests
.testFailedBundleNeverGatesTheScreen` sets `failedBundle` on a real
`WorkoutManager` and asserts the result is `.start` (then `.live` once
`isRunning` flips), through this exact call. **Honest limitation:** this
catches a regression in the decision function itself or in what `body`
switches on; it would NOT catch a regression that wraps the whole switch in
a brand-new, independent `if failedBundle != nil` check that bypasses
`Self.screen(for:)` entirely — no tool available here (no ViewInspector) can
close that last gap. Flagged in "things I'm unsure about" below.

Also renamed `WorkoutScreenSelectionRegressionTests` →
`WorkoutScreenSelectionHistoricalFixtureTests` and rewrote its doc comment to
say explicitly: **documentation only, not regression coverage** — it exercises
a hand-copied replica of the pre-fix logic frozen at commit `85764b3`, so it
cannot fail for a reason that reflects current behavior. Never cite it as
evidence a fix works.

**(b) Rest-alarm actor isolation.** `WorkoutManager.swift`,
`scheduleRestAlarm()`: pre-hoist, this lived on a SwiftUI View (implicitly
MainActor), so its bare `Task { … }` inherited MainActor isolation for free.
Post-hoist, `scheduleRestAlarm()` itself isn't `@MainActor` (it's called from
`restTargetS`'s `didSet`, a synchronous nonisolated context that can't call
an isolated method directly), so the same `Task { … }` no longer reliably ran
on the main thread — a real regression, not just a style nit, since
`WKInterfaceDevice` haptics belong on the main thread and `restAlarmTask`
must only ever be touched from there. **Fix:** `Task { @MainActor in … }`,
matching the pattern this same file already uses for HealthKit's background
delegate callbacks (`workoutSession(_:didFailWithError:)`,
`didCollectDataOf:`).

## Findings from REVIEW.md and what changed

### F1 (HIGH) — a save outcome from workout N could render over a running N+1; a `.lost` save could lock Start out forever

Two independent fixes, both required:

1. **Render order.** `WorkoutLiveView.body` used to check
   `failedBundle != nil`, then `justSaved`, then `isRunning`, then default to
   Start. Extracted the decision to a pure, unit-tested Core function —
   `WorkoutScreenSelection.screen(isRunning:justSaved:)`
   (`SendLogWatchCore/WorkoutScreenSelection.swift`) — which checks
   `isRunning` **first** (a running workout always wins the render) and does
   not take `failedBundle` as a parameter **at all**. `WorkoutLiveView.body`
   is now a `switch` over this function's result — a thin pass-through, not a
   second copy of the decision.
2. **`failedBundle` is no longer a competing exclusive screen.** It's
   preserved (`WorkoutManager.start()` deliberately does **not** reset it —
   discarding it would be a second, silent loss of the #287 last in-memory
   copy of an unsaved workout) but it's now surfaced as a non-blocking banner
   *inside* `startContent` (`WorkoutLiveView.failedSaveBanner`), alongside the
   "Start Workout" button, not instead of it. Start is reachable whenever
   nothing is running and nothing was just saved — full stop, regardless of
   whether a previous save failed.
3. **`start()` explicitly decides the fate of all four fields**
   (`WorkoutManager.swift`, in `start()`'s reset block): `ending`,
   `justSaved`, `stillQueued` are cleared (per-save transients, nothing to
   lose); `failedBundle` is left untouched, with an inline comment explaining
   why and pointing at `WorkoutScreenSelection` for the render-order half of
   the fix. `save()`'s success path still unconditionally clears
   `failedBundle` on ANY successful save (pre-existing behavior, unchanged —
   noted, not touched, since changing it would mean queuing multiple failed
   bundles, a bigger behavior change than this finding asked for).

**Regression tests, verified to fail on commit `85764b3`:**
- `WorkoutSavePathResetTests.testStartClearsPerSaveTransientsFromAPreviousWorkout`
  (`SendLogWatchTests`, runs against the real `WorkoutManager.start()`): sets
  `justSaved`/`stillQueued`/`ending` to `true`, calls `start()`, asserts all
  three are `false` after. **Verified to fail on `85764b3`** — I stashed just
  `WorkoutManager.swift` back to the reviewed commit (keeping the new test
  file), ran it on the booted simulator, and got exactly the expected
  failures (`justSaved`/`stillQueued`/`ending` all still `true`), then
  restored the fix and reconfirmed the full suite green.
- `WorkoutScreenSelectionRegressionTests` (`SendLogWatchCoreTests`) is a
  historical fixture: it inlines a faithful, minimal copy of
  `WorkoutLiveView.body`'s decision **as it stood on commit `85764b3`**
  (comment-annotated with the `git show` command to verify it), and proves
  that copy renders `.failedSave`/`.saved` over a running workout, and can
  never return `.start` while `failedBundlePresent` is true regardless of any
  other state. This can't "fail on 85764b3" via `swift test` (it's new code,
  by definition), but it's not passing by construction either — it's testing
  a faithful transcription of the actual old logic, compared against the
  new one.
- `WorkoutSavePathResetTests.testStartSucceedsWithAStaleFailedBundlePresentAndPreservesIt`
  passes on **both** old and new code — noted honestly rather than presented
  as a regression test. The reason: at the `WorkoutManager` level, `start()`
  was **never** blocked by `failedBundle` (old or new) — the lockout was
  purely a *view*-level bug (the Start button was unreachable, not that
  `start()` itself refused to run). A manager-only test can't capture a
  view-only bug; `WorkoutScreenSelectionRegressionTests` above is what
  actually proves scenario B.

**Known minor gap, not fixed:** if a user retries a failed save (`ending =
true` inside `retryFailedSave()`) and then starts a new workout while that
retry is still in flight (now possible, since Start is always reachable), the
new workout's `start()` resets `ending = false`, which can make the failed
save's "Retrying…" button look enabled for a moment even though the retry is
still running in the background. This is cosmetic only (no data loss — the
retry's own completion still runs to completion and sets `failedBundle`
correctly either way) and wasn't part of any review finding; flagging it here
rather than adding more state to close a non-data-loss edge case, per the
review's explicit steer toward small fixes.

### F2 (MEDIUM) — `signedOut` preserved the data but `WaitingForPhoneView` had no End control

`WaitingForPhoneView` now reads `@Environment(WorkoutManager.self)` and shows
a banner + "End Workout" button whenever `workout.isRunning`, calling
`workout.endAndSave()` directly (no `NavigationStack` needed — this screen
doesn't have one). The `RELEASE_NOTES.md` claim ("the workout stays reachable
to end") is now true on this path too; left the wording as-is since it's
accurate.

### F3 (MEDIUM) — `startFusion()` still overwrote `fusionTimer` without invalidating

Moved `fusionTimer?.invalidate()` to the top of `startFusion()` itself, with
a comment quoting the issue's own root-cause line. The invariant is now local
to the function that owns `fusionTimer`, not dependent on `start()`'s guard
being the only caller. (`start()`'s guard is still the correct fix for the
*double-tap* scenario — this closes the separate "any future caller" gap the
review flagged.)

### F4 (MEDIUM) — the `status` mitigation hint lived on the wrong page

Moved the "Workout running — tap Climb Workout to end it" hint from
`ActionsView` (home page 2) to a persistent banner in `HomeView`, positioned
above the `TabView` pager — visible on whichever page is selected, including
page 1 (`StatusView`), which is where `open(_:)` sends a `status` deep link.
Removed the now-redundant copy from `ActionsView`.

### F5 (LOW) — the rest-over haptic was silently dropped by any mid-workout deep link

Hoisted the rest alarm (`restAlarmTask`, `scheduleRestAlarm()`,
`cancelRestAlarm()`) from `WorkoutLiveView` into `WorkoutManager`, same
reasoning as the save path: triggered directly off `restStartedAt`
transitions (`start()`, `toggleManualAttempt()`, the auto-detector transition
in `startFusion()`, and `restTargetS`'s `didSet`), and cancelled in `end()`.
It no longer depends on the view being on screen — this is a real fix, not
just documentation, per the review's "fix or document" framing.

### F6 (LOW) — `deinit`'s timer invalidation is effectively dead code in production

Recorded honestly, not fixed further (per the review's own framing — "keep it
as defence-in-depth if you like"): the only production `WorkoutManager` is
`@State` in `SendLogWatchApp`, whose storage lives for the process, so
`deinit` never runs in the shipping app. **F3 is the change that carries real
weight** for the timer-orphan risk; the acceptance criterion "`fusionTimer`
is `nil` after `deinit`" is structurally satisfied (the test passes, and
still does) but is not a shipped behavior change — it exercises a code path
production never takes.

### F7 (LOW) — `session`/`builder`/`startDate`/`liveSync` reset defensively

Added `session = nil; builder = nil; startDate = nil; liveSync = nil` to
`start()`'s reset block, alongside the F1 fields. Not currently reachable
(every path that sets them also runs `end()`), but closes the same
long-lived-manager exposure at no cost, as the review noted.

**Explicitly not fixed (per this round's instructions):** the pre-existing
hazard the review named at the end of its F7 — `session.startActivity(with:)`
succeeding then `builder.beginCollection` throwing, which orphans an
unreachable `HKWorkoutSession` — is out of scope; the user said they're
filing it separately.

### F8 (LOW) — restored #189's load-bearing rationale comment

Restored the full seven-line comment on `stillQueued` explaining *why* it
must be read right after `WidgetBridge.refreshStatus()`'s round trip and
right before showing `justSaved` (it was compressed to two lines in the
original hoist, losing the constraint, not just the fact).

## Validation run (round 2, F1–F8)

- `swift test`: 221/221. Watch app build: succeeded (caught and fixed one
  self-inflicted regression: an edit to `WorkoutManager`'s doc comment
  accidentally deleted the `var failedBundle` declaration itself — caught
  immediately by the build, restored). `SendLogWatchTests` on simulator:
  117/117. F1 regression test independently verified to fail on `85764b3`
  (stashed `WorkoutManager.swift` back, reran, confirmed the expected
  failure, restored, reconfirmed green).

## Validation run (round 3, R1–R3) — ⚠️ CORRECTED, see round 4 below

**The "120/120 passed" claim below was false as stated — it was a single run,
not a repeated one, and the reviewer's final pass measured the true pass rate
at 2 failures in 5 runs (~60%). See "Validation run (round 4, X1/X2)" further
down for the corrected figures and the fix.** Left as originally written
below, for the record — this is what the branch's third-round handoff
actually claimed, and the correction belongs beside it, not in place of it.

- `cd ios/App/SendLogWatchCore && swift test` — **221/221 passed** (same
  count as round 2 — `WorkoutScreenSelectionRegressionTests` was renamed to
  `WorkoutScreenSelectionHistoricalFixtureTests`, no tests added or removed
  in Core this round; the new tests are App-target).
- `xcodebuild build -project ios/App/App.xcodeproj -scheme "SendLogWatch Watch App" -destination "generic/platform=watchOS Simulator" CODE_SIGNING_ALLOWED=NO`
  — **BUILD SUCCEEDED**.
- `xcodebuild test -destination "id=<Apple Watch Series 11 (42mm) sim>" -only-testing:SendLogWatchTests`
  — **120/120 passed** (118 + 2 new R1 tests:
  `testSuccessfulSaveDoesNotClearAnUnrelatedFailedBundle`,
  `testSuccessfulSaveClearsItsOwnMatchingFailedBundle`; R3a's
  `testFailedBundleNeverGatesTheScreen` was the 118th, added earlier in this
  same round). The two `save()`-exercising R1 tests are noticeably slower
  (~16s each) than the rest of the suite — `WidgetBridge.refreshStatus()`
  inside `save()`'s success path retries real network calls against
  `127.0.0.1:54321` with backoff before giving up in this sandboxed host;
  it fails gracefully (cached data preserved) rather than hanging, but it's
  not fast. Not a correctness concern, flagging for anyone surprised by the
  suite taking ~32s total instead of a fraction of a second.
- **Fail-before-fix, independently reproduced** for the R1 regression tests:
  stashed `WorkoutManager.swift` back to commit `47e52e3` (the round-2 commit,
  keeping the new test file), ran
  `-only-testing:SendLogWatchTests/WorkoutSavePathResetTests`: both new tests
  **failed to compile** (`'save' is inaccessible due to 'private' protection
  level` — `save()` wasn't yet exposed on that commit), which is the
  strongest form of "fails on prior code." Popped the stash, rebuilt, reran
  the full suite: 120/120 green again.
- Web: not touched, `npm run typecheck/lint/test/build` not applicable.

## Validation run (round 4, X1/X2, this revision) — the corrected figures

- `cd ios/App/SendLogWatchCore && swift test` — **224/224 passed** (221 + 3
  new `FailedBundleClearTests`).
- `xcodebuild build -project ios/App/App.xcodeproj -scheme "SendLogWatch Watch App" -destination "generic/platform=watchOS Simulator" CODE_SIGNING_ALLOWED=NO`
  — **BUILD SUCCEEDED**.
- **`xcodebuild test -destination "id=<Apple Watch Series 11 (42mm) sim>" -only-testing:SendLogWatchTests`, run FIVE consecutive times, as explicitly
  instructed — not a single run reported as fact:**

  | Run | Result | Total test time |
  |---|---|---|
  | 1 | 118/118 passed, `** TEST SUCCEEDED **` | 0.746s |
  | 2 | 118/118 passed, `** TEST SUCCEEDED **` | 0.499s |
  | 3 | 118/118 passed, `** TEST SUCCEEDED **` | 0.297s |
  | 4 | 118/118 passed, `** TEST SUCCEEDED **` | 0.229s |
  | 5 | 118/118 passed, `** TEST SUCCEEDED **` | 0.234s |

  **5/5 = 100% pass rate**, every run under a second, no network log output in
  any of the five (confirmed by inspecting each run's full log, not just the
  summary line). Compare to the pre-fix measurement (by the reviewer, on
  unmodified `5bc2fa9`): 2 failures in 5 runs, ~32s per run. 118 = the prior
  120 minus the two removed flaky tests (`testSuccessfulSaveDoesNotClear...`,
  `testSuccessfulSaveClearsItsOwn...`), which were exercising the same
  invariant `FailedBundleClearTests` now covers, in Core, in microseconds.
- **X2 verified by breaking it before being fixed**: temporarily reinstated
  `if workout.failedBundle != nil { … } else { switch Self.screen(for:
  workout) { … } }` in `WorkoutLiveView.body`, ran
  `-only-testing:SendLogWatchTests/WorkoutOwnershipTests`: **3/3 passed**,
  confirming `testFailedBundleNeverGatesTheScreen` does not catch that
  regression shape, exactly as the reviewer found. Reverted before writing
  the corrected comment.
- Web: not touched.

## Things I could NOT verify from here (manual/device matrix — updated)

Everything from the original handoff's matrix still applies (deep-link
navigation rendering, a real `signedOut` relay against a live
`HKWorkoutSession`, a real double-tap against real HealthKit, widget/Smart
Stack behavior, `failedBundle` surviving a real save failure across a torn-
down view). Adding, specific to this round:

| Scenario | Why untestable here | How to check |
|---|---|---|
| Workout N's save actually failing (`.lost`) while workout N+1 is started and running, observed end-to-end on a real device — does the "Last workout not saved" banner appear correctly once N+1 later ends, with N's bundle still retryable | Needs a real network-down + real HealthKit session; this test host has neither reliably | Airplane-mode the watch, start a workout, End it (save goes `.lost`), start a NEW workout without retrying, confirm the new workout runs with a full End control reachable, end it too, then confirm the ORIGINAL failed bundle's Retry Save banner is still present and retryable |
| The `WaitingForPhoneView` End button, tapped for real while `HKWorkoutSession` is live and the phone is genuinely signed out | No HK entitlement / no real auth relay in this test host | Paired sims or device: start a workout, force a `signedOut` relay, confirm the banner + End button appear and actually end the session, then sign back in and confirm History has the workout |
| The `HomeView` persistent banner's layout on a 40mm screen with the "1 pending upload" line also showing (does it feel cramped) | Layout-only concern, needs visual review | Screenshot on a 40mm simulator with a workout running AND a pending upload simultaneously |

## Things I did NOT touch

Same as the original handoff: `OfflineQueue.swift`, `Repo.swift`,
`AttemptDetector.swift` untouched; no Part B; no detector-behavior changes.
The pre-existing `startActivity`/`beginCollection` orphan hazard (first noted
as a side comment on the first review's F7) is explicitly left alone —
**it's now tracked as issue #480** and is out of scope for this branch by
explicit instruction.

## Things I'm unsure about / worth a second look

- **The `failedSaveBanner` redesign is a real (small) UI change**, not just a
  logic fix: the old `failedSaveContent` was a full-screen "Workout not
  saved / Keep this screen open and retry" message; it's now a compact
  banner above the Start button. This was necessary to make Start reachable
  (scenario B), but a reviewer should sanity-check the new copy/layout fits
  a 40mm screen alongside the existing "Tracks heart rate…" text and error
  message — I couldn't screenshot-verify this from here (no Xcode Previews
  render available in this environment; the `#Preview` blocks exist but
  weren't visually inspected).
- **The `ending`-reset interaction with an in-flight retry**, described
  above under F1's "known minor gap" — flagging again here in case a
  reviewer wants it closed rather than accepted, though it's cosmetic only.
- **`WorkoutScreenSelectionHistoricalFixtureTests`'s pattern** (a hand-copied,
  comment-cited replica of old buggy logic, compared against the new one) is
  now explicitly labeled documentation-only per R3, but is still not
  something this repo had a precedent for before this branch. If unwelcome,
  the alternative is deleting those 4 tests outright and relying solely on
  `WorkoutScreenSelectionTests` + `WorkoutOwnershipTests
  .testFailedBundleNeverGatesTheScreen` (both exercise real production code).
- **`WorkoutLiveView.screen(for:)`'s honest gap (confirmed, not just stated —
  see X2 above)**: it catches a regression in the decision function itself or
  in what `body` switches on today, but NOT a hypothetical future regression
  that wraps the whole `switch` in a brand-new `if failedBundle != nil` check
  that never calls `screen(for:)` at all — I verified this by actually doing
  it and watching the test stay green. No tool available in this environment
  (no ViewInspector, `@Environment` unresolvable outside a hosted view) can
  close that last gap. Flagging again here in case a reviewer has a way to
  close it that I don't; the comment on the test now states this limitation
  directly rather than the disproven stronger claim.
- **`save()` is `private` again** (X1) — the R1 invariant it enforces is
  tested in Core now (`FailedBundleClearTests`), and `save()`'s own wiring to
  it is a one-line, inspection-verifiable call. No outstanding question here.
