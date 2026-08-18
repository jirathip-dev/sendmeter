# PERF-671 — BLE stream→UI publishing coalescing

Issue: [#671](https://github.com/sendmeter/sendmeter/issues/671) — native perf:
coalesce BLE stream→UI publishing. Scope: publish path only (AppModel split
domain, #672, untouched).

## Problem (before)

The native BLE→UI path was *less* coalesced than the web version it replaces:

- `TindeqBluetooth.updatePublishedValues()` assigned **5 `@Published`
  properties on every BLE notification** (`currentKilograms`, `peakKilograms`,
  `averageKilograms`, `elapsedMilliseconds`, `visibleSamples`).
- `visibleSamples = accumulator.visibleWindow()` did an **O(window) `Array`
  copy per notification** (~800 elements at a 10 s window, ~83 Hz fake-gauge
  stream) — `ForceSessionAccumulator.visibleWindow()` returned
  `Array(samples[low...])`.
- Each `didUpdateValueFor` paid a **`Task { @MainActor }` hop** even though
  `CBCentralManager` is created on `.main`.
- No display-rate throttle. The web app coalesces to display rate via rAF
  (`src/hooks/useTindeq.ts:257-268`); native had no equivalent, so SwiftUI
  invalidation fired at BLE notification rate during a pull.

## Fix (after)

1. **Display-rate flush driver** (`TindeqBluetooth.swift`): BLE notifications
   now only accumulate into `ForceSessionAccumulator` and set a `pendingPublish`
   flag. A ~60 Hz `Timer` (added to `.common` runloop mode so it keeps firing
   during scroll tracking) flushes the published values at most once per
   display frame. **The timer IS the throttle — one cadence source.** A fire
   publishes iff `pendingPublish` is set; there is deliberately no second
   time-gate. (An early revision gated each fire on
   `now - lastFlushTime >= 1/60 s`; two throttles with the same period beat
   against each other and dropped 22–43% of the fires — a 30–50 Hz irregular
   trace, the issue's fail condition. Removed in review; the scheduler test
   pins the no-skip invariant.)
2. **Window published as a range over stable storage** (`ForceEngine.swift`):
   `ForcePublishSnapshotBuilder` computes `ForceSessionAccumulator.visibleRange`
   at flush time; the driver then does exactly **one `Array(accumulator.samples[
   visibleRange])` copy at flush time** — display rate, never notification rate.
   The accumulator buffer itself is only reallocated by appends. The old
   `visibleWindow()` zero-copy `ArraySlice` still exists as the seam's
   proof-of-storage-sharing, but the shipped publish path reads the range. This
   is a copy, not "zero-copy": the chart needs a value array, and a raw
   published slice would retain the accumulator buffer (paying a full-array
   CoW on every later append). `#671` makes the copy *less frequent*, which is
   the win.
3. **`Task { @MainActor }` hop dropped** in `didUpdateValueFor`: the delegate
   already runs on `.main`; the body now runs under `MainActor.assumeIsolated`
   (the class is `@MainActor`), eliminating a per-notification Task
   allocation + actor hop. (Other CB delegates still hop; verified safe — see
   the review's F7 trace.)
4. **Hands-free arming unaffected**: `onWeightSample` still feeds every parsed
   sample to the arming loop pre-start; pre-start samples still never enter
   the accumulator. The armed-but-not-recording live reading is published from
   `lastSampleKilograms` at flush time — **and is the only field published
   while armed** (a single `objectWillChange` pulse per flush, not two).
5. **Final flush on stop** (`stopFlushDriver`): every exit path
   (stop/disarm/disconnect/reset) publishes any pending frame before
   invalidating the timer, so the post-stop metric card's peak/elapsed match
   the summary that was just saved.
6. **Debug evidence counter**: DEBUG builds publish `publishesPerSecond` (the
   flush driver's measured publish rate, zero outside DEBUG), so the
   coalescing win is observable at runtime in the simulator with the fake
   transport.

## Evidence — publishes/sec at stream rates

The publish rate of the **shipped driver** is exactly the timer cadence: the
60 Hz fire sequence with realistic jitter, and each pending fire publishes
(no skip). The test
`testPublishBenchDrivesShippedSchedulerAtTimerCadence` drives the actual
scheduler rule with a simulated 60 Hz fire sequence (schedule + accumulating
jitter) and counts publishes:

| Stream | Rate | Before (no coalescing) | After (shipped driver) |
|---|---|---|---|
| Fake-gauge (`?fake-tindeq`, `useTindeq.ts:515-520`) | ~83 Hz (12 ms) | **~83 publishes/s** (one per notification) | **~60 publishes/s** (every 16.7 ms fire; F1-skip fraction 0) |
| Fast Progressor batches | ~100 Hz (10 ms) | ~100 publishes/s | **~60 publishes/s** (same cadence) |
| Real Progressor stream | ~80 Hz (12.5 ms) | ~80 publishes/s | **~60 publishes/s** (same cadence) |

The "~83 Hz" rows are the *arrival rates* the timer's fires get saturated by —
publishes are independent of them. The bounded number is the driver's display
cadence, and every fire publishes (the review's F1 skip fraction, 22–43%, is
zero by construction — the scheduler test asserts it). Before: one publish
(5 `@Published` assignments + an O(window) array copy) per notification. After:
one `objectWillChange` pulse per 16.7 ms timer fire with pending samples, and
one window copy per fire — never per notification.

The DEBUG `publishesPerSecond` counter (a real in-app measurement) reads the
same number on a live fake-gauge run in the simulator: it counts flushed
publishes per second in `flushIfDue`. The deterministic bench above reproduces
it exactly (the counter divides the same count by the same elapsed time).

The per-notification O(window) copy is gone from the hot path entirely. What
remains is the single `Array(...)` at flush time — display rate, not
notification rate.

## Acceptance criteria

- ✅ View-body evaluations bounded at ≤ display rate, independent of BLE rate:
  the timer's fire cadence is the one and only throttle; every pending fire
  publishes; the bench drives the shipped scheduler rule at a jittered 60 Hz
  sequence and asserts the bound and the zero-skip invariant.
- ✅ No per-notification O(window) copy on the hot path: notifications only
  append + set `pendingPublish`; the window copy happens once per flush from
  the accumulator's stable storage.
- ✅ `swift test` stays green (282 tests, 0 failures); hands-free arming
  unaffected (pre-start samples still consumed only by `onWeightSample`); new
  tests cover the scheduler cadence/no-skip, the snapshot branch fields (F8),
  and the window-range slice.
- ✅ Evidence above (deterministic bench driving the shipped scheduler at the
  fake-gauge stream rate + the DEBUG in-app counter that reads the same
  number).

## Gates run

```
cd native/SendmeterNative
swift test                       # 282 tests, 0 failures
xcodegen generate                # OK
xcodebuild -project SendmeterNative.xcodeproj \
  -scheme SendmeterNative \
  -destination 'generic/platform=iOS Simulator' build   # BUILD SUCCEEDED
```
