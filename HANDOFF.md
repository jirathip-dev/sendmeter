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

## Validation run (this revision)

- `cd ios/App/SendLogWatchCore && swift test` — **221/221 passed** (213 from
  the original round + 8 new: 4 `WorkoutScreenSelectionTests`, 4
  `WorkoutScreenSelectionRegressionTests`).
- `xcodebuild build -project ios/App/App.xcodeproj -scheme "SendLogWatch Watch App" -destination "generic/platform=watchOS Simulator" CODE_SIGNING_ALLOWED=NO`
  — **BUILD SUCCEEDED**. (Caught and fixed one self-inflicted regression
  along the way: an edit to `WorkoutManager`'s doc comment accidentally
  deleted the `var failedBundle: WorkoutSaveBundle?` declaration itself —
  caught immediately by this build, restored, rebuilt clean.)
- `xcodebuild test -destination "id=<Apple Watch Series 11 (42mm) sim>" -only-testing:SendLogWatchTests`
  — **117/117 passed** (115 from the original round + 2 new
  `WorkoutSavePathResetTests`).
- **Fail-before-fix, independently reproduced** for the F1 regression test:
  stashed `WorkoutManager.swift` back to commit `85764b3` (keeping the new
  test file and everything else), ran
  `-only-testing:SendLogWatchTests/WorkoutSavePathResetTests`:
  `testStartClearsPerSaveTransientsFromAPreviousWorkout` **failed** with
  exactly the expected assertion failures (`justSaved`/`stillQueued`/`ending`
  all still `true` after `start()`); `testStartSucceedsWithAStaleFailedBundlePresentAndPreservesIt`
  passed on old code too (expected — see F1's writeup above for why). Popped
  the stash, reran the full suite: 117/117 green again.
- Web: not touched, `npm run typecheck/lint/test/build` not applicable.

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
`AttemptDetector.swift` untouched; no Part B; no detector-behavior changes;
the pre-existing `startActivity`/`beginCollection` hazard the review flagged
in F7 is explicitly left alone per this round's instructions (filed
separately by the user).

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
- **`WorkoutScreenSelectionRegressionTests`'s historical-fixture pattern** (a
  hand-copied, comment-cited replica of old buggy logic, compared against
  the new one) is not something this repo had a precedent for before this
  branch. If this pattern is unwelcome, the alternative is dropping those 4
  tests and relying solely on the empirically-verified
  `WorkoutSavePathResetTests` (which only covers the reset half of F1, not
  the render-order half) plus code inspection of `WorkoutLiveView.body`
  being a thin `switch` over `WorkoutScreenSelection.screen(...)`.
