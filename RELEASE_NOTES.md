# Release notes

This is the canonical source of truth for user-facing changes since the last
App Store release. Add a concise, plain-language bullet under the best category
when a change affects what users can see or do (for example, `- Force recordings
now show the selected grip type in History.`). Leave out internal maintenance,
CI, dependency updates, and refactors unless users experience a change.

## Unreleased

### Added

### Improved

- See your 28-day activity mix at a glance with a proportional training-load bar.
- Filter History by session type and Force tag, including loose Force recordings.
- Force: Hands-free mode now runs every static sensor protocol pull-by-pull, records completed and early-release outcomes, and waits safely for unload before the next rep.
- Force equipment setup is now concise, optional guidance without checklists or training blockers.
- Switch the Force protocol list clearly between Static and Reverse Action modes, with color-coded badges and mode-matched presets.

### Fixed

- Linking loose Force recordings to a session (the "link to this session" nudge) is now all-or-nothing — a failure partway through no longer leaves recordings regrouped without the session actually reflecting them.
- Account: "Clear health data & resync" no longer shows a permanent "resync failed" warning for an account with no Health history to rebuild in the first place, and the success message on web now correctly says to open the iPhone app to resync instead of claiming this device will do it.
- Restore the Tare button in the Force fullscreen gauge so a non-zero load-cell baseline can be zeroed again.
- Force: fixed hands-free adaptive reps failing to save (with a "Failed to save recording" error) after the first rep of a run.
- Force: fixed a disconnect while hands-free was armed (before the first pull) silently discarding a later normal run's recordings, and fixed switching or clearing a static preset after a hands-free run carrying that run's stale state into the new one.
- Routine now has its own distinct color in the activity-mix bar, legend, and heatmap instead of looking identical to Antagonist.
- Activity-mix percentages no longer round a real, visible share down to 0% — small shares now show as "<1%".
- Fixed grouping a just-edited Force recording into a session (or moving it into an existing one) sometimes leaving it stuck showing as loose until reload.
- History, Peak Force Trend, and %BW now date recordings by your local day instead of UTC, so sessions and reps made before 07:00 no longer land on the wrong day.
- History: changing a filter no longer leaves hidden recordings in a bulk selection, a Force tag chip no longer targets sessions it can't match, and tags hidden in the Force tab no longer resurface as filter chips.
- History: a type or Force tag filter now resets to "All" for good when its last matching recording or session is removed, instead of silently re-applying itself once matching data reappears.
- History: recordings grouped into a session no longer vanish for good if that session is later deleted; deleting a ticked recording now immediately updates the bulk-action count instead of leaving a stuck button; and "Assign…" no longer writes to a recording that was ticked then deleted.
- Force: a non-hands-free run right after a hands-free run no longer plays stray "done" cues or shows a stale danger banner on segment transitions.
- Force: a BLE disconnect during the first rep of a session now auto-logs the recovered session to History instead of silently dropping it until a later disconnect.
- Force: retrying unsaved recordings no longer discards a rep that failed to save while the retry was in progress, and a single-sample recording can no longer get permanently stuck failing to sync.
- Watch: fixed the live workout mirror silently freezing partway through a long session — the watch now notices its sign-in has gone stale and asks the phone for a fresh one instead of waiting on an app foreground or reachability change that may never come.
- Watch: a same-tick Play/Stop (or ending a workout without tapping Stop) no longer logs a zero-length boulder attempt, and a single upload the server permanently rejects (or one that keeps failing for an unrecognized reason) no longer blocks every other watch workout behind it in the offline queue. History now shows a distinct notice on the phone when a watch workout could not be uploaded and will not retry, instead of going silent.
- Watch: fixed automatic boulder detection re-opening a phantom attempt on the very next tick after a real one closed — this made the Stop/Play button look unresponsive and merged an entire session into one multi-minute "attempt". An automatically-detected attempt that gets stuck at floor level or stuck at altitude (barometric drift, whether still or walking) now closes on its own within a bounded time instead of running for up to 5 minutes, and pressing Stop on a short attempt now always logs it. Automatic detection of a flat, HR-only "traverse" (little to no height gain) is deliberately retired as part of this fix — it could not be told apart from ordinary walking between boulders, so log one with the Boulder/Stop button instead; a manually-logged attempt is never cut short by these new time bounds, and now also closes on its own once you stand still even on a stretch where the watch didn't have a fresh heart-rate reading (it's bounded the same generous way every attempt always has been, otherwise). Because this bug also skewed the on-device RPE prediction model's training, that model now retrains only from workouts recorded after this fix, so predictions stay a plain formula (not model-based) for a little while after updating rather than relearn the bug; boulder counts and durations recorded before this fix may be unreliable and were not corrected retroactively. Note: while a heart-rate reading is temporarily unavailable (sensor gap, loose watch), automatic detection needs a bit more height gain than usual (roughly 1m instead of 0.45m) before it opens an attempt on its own — real boulders are unaffected, but a very low, subtle move might need the Boulder button during that stretch.
- Watch: a workout stuck behind an expired sign-in now actually asks the paired iPhone for a fresh one instead of silently waiting, and a failed upload retries automatically on its own even with the watch untouched. The watch now also shows when its upload queue hasn't synced in a while.
- Watch: a running Climb Workout no longer gets silently orphaned by tapping a Force or status complication, or by the app losing its connection to your iPhone mid-workout — the workout, its boulder count, and an unsaved workout waiting to retry now survive, and the workout stays reachable to end.
- Watch: a heart-rate sensor gap or bad wrist contact during a Climb Workout no longer silently holds the last reading forever — auto boulder detection, the HR chart, and your live heart rate on the phone now correctly show it as unavailable instead of a stuck stale number, and ending a workout while a background sync is still catching up can no longer inflate its saved duration or leave the saved session with a truncated, out-of-date summary.
- Routine: reopening the Workout tab long after leaving a routine mid-way no longer silently auto-resumes it and logs a fabricated session duration. A routine you actually finished is now logged as completed even if the screen locked right at the end; one you genuinely abandoned partway logs only the real time you spent (with a toast either way, never silently); and Skip no longer inflates the logged duration to the routine's full nominal length.
- Routine: the screen no longer auto-locks while a guided routine is running, so leaving the phone alone mid-routine no longer under-logs (or fails to log) how long it actually took.
- Routine: preset totals in the Workout tab now include the routine's lead-in countdown to match the running timer, so a listed total may read a few seconds longer than before (e.g. "9m" → "9m5s").
- Readiness (iPhone and watch) no longer counts training you've deleted in newly computed scores — a deleted session drops out of today's readiness immediately. Your stored history for the days before still reflects the deleted training until you run "Clear health data & resync" to rebuild it.
- "Clear health data & resync" now tells you honestly if the resync failed to rebuild your history, instead of always saying "resyncing" even when it didn't.
- Force: a recording that's queued while offline now logs against the day it was actually recorded, not the day it happens to finally upload.
- The offline recording queue now retries automatically when the app comes back to the foreground, when your connection returns, and periodically in the background (backing off if nothing's moving), instead of only once right after sign-in — a session that went offline and never got reloaded now still syncs. A recording the server keeps rejecting no longer blocks every recording queued after it and is never deleted — it's kept and retried until it's confirmed stuck, at which point Force and History show it as its own "stuck, not retrying" state with a Retry action, rather than losing it silently. The pending-upload count shown in Force and History no longer includes recordings stranded under a different account, and signing out with unsynced recordings left over now only offers to delete the recordings it actually counted, never another account's.
- Force: a whole-buffer recording recovered after a sign-out or connection loss can no longer enter your force curve (and the training targets/watch RPE prediction derived from it).
- Force fullscreen: Disconnect now asks for confirmation while a rep is measuring, armed, or counting down, instead of silently discarding it.
- Watch: force recordings now queue and retry like workouts and gauge sessions do, so a gym-basement outage no longer loses a rep outright.

## 1.0 — 2026-08-02

### What’s New in This Version

- Train Reverse Action protocols with or without a Tindeq: cadence-only sessions save progress, while measured results stay separate from Static holds.
- Set up Force sessions with clearer equipment guidance and repeatable reference marks.
- Open the ACWR card for weekly, daily, and 28-day training-load details.
- Let Apple Watch detect bouldering attempts automatically from wrist motion, height, and heart-rate changes.
- Dismiss mobile sheets more reliably with an easier-to-reach handle and a short downward flick.
