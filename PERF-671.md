# PERF-671/#783 — BLE stream→UI publishing coalescing

Issue: [#671](https://github.com/sendmeter/sendmeter/issues/671) — native perf:
coalesce BLE stream→UI publishing. Follow-up: [#783](https://github.com/sendmeter/sendmeter/issues/783)
removes the remaining live-window materialization and adopts Swift Observation
for the native models.

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
   at flush time. #671 first moved that work to display cadence; #783 completes
   the path with a stable reference-backed `ForceSampleBuffer`. The live Canvas
   indexes that buffer over the published range, so it does not build either a
   full visible-window `Array` or an `ArraySlice` during a BLE notification or
   display flush. The old `visibleWindow()` remains only as a compatibility
   helper for non-live callers.
3. **`Task { @MainActor }` hop dropped** in `didUpdateValueFor`: the delegate
   already runs on `.main`; the body now runs under `MainActor.assumeIsolated`
   (the class is `@MainActor`), eliminating a per-notification Task
   allocation + actor hop. (Other CB delegates still hop; verified safe — see
   the review's F7 trace.)
4. **Hands-free arming unaffected**: `onWeightSample` still feeds every parsed
   sample to the arming loop pre-start; pre-start samples still never enter
   the accumulator. The armed-but-not-recording live reading is published from
   `lastSampleKilograms` at flush time — **and is the only field published
   while armed** (a single model update per flush, not two).
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
timer is scheduled with `ForcePublishScheduler.displayIntervalSeconds`
(`TindeqBluetooth.startFlushDriver()`), and every pending fire publishes (no
second gate, so no skip). The test
`testPublishBenchRunsAtShippedDisplayCadence` derives the fire sequence from
that same shipped interval and counts publishes:

| Stream | Rate | Before (no coalescing) | After (shipped driver) |
|---|---|---|---|
| Fake-gauge (`?fake-tindeq`, `useTindeq.ts:515-520`) | ~83 Hz (12 ms) | **~83 publishes/s** (one per notification) | **~60 publishes/s** (60 fires at 16.7 ms cadence, every pending fire publishes) |
| Fast Progressor batches | ~100 Hz (10 ms) | ~100 publishes/s | **~60 publishes/s** (same cadence) |
| Real Progressor stream | ~80 Hz (12.5 ms) | ~80 publishes/s | **~60 publishes/s** (same cadence) |

A real repeating `Timer` keeps its absolute schedule — fire *k* is scheduled at
`k·interval` and lateness never compounds into the period — so the bench models
exactly that: an absolute schedule plus a small independent (non-accumulating)
jitter per fire. The assertions are on the cadence itself: the fire sequence
must be 58–61 fires over a simulated second, so a degenerate sub-cadence (the
review's round-2 measurement of the earlier cumulative-jitter model degenerating
to 41/s) fails the test rather than passing it. The stream rows above are the
*arrival rates* the timer's fires get saturated by — publishes are independent
of them.

Before #671: one publish (5 published assignments + an O(window) array copy)
per notification. After #783: one Swift Observation update per 16.7 ms timer
fire with pending samples, and the Canvas indexes the shared buffer directly —
no window copy at notification or display rate.

The DEBUG `publishesPerSecond` counter (`TindeqBluetooth`) is the in-app
observability seam for this: it divides the same flushed-publish count by the
same elapsed time in `flushIfDue`, so it reads the same ~60/s number the
deterministic bench above produces. It is debug-only and zero outside DEBUG
builds; no simulator capture is shipped with this doc because the native
transport has no fake-gauge driver to drive it in this repo.

The per-notification O(window) copy was removed by #671; #783 removes the
remaining display-rate window copy as well. The only full-array conversions are
non-live summary/persistence paths.

## #783 follow-up

`TindeqBluetooth` and `AppModel` are now `@Observable` and injected with typed
SwiftUI Observation environment values. The platform services that still need
their iOS 16/macOS 13 floors remain Combine-based behind small revision
bridges, while the hot force transport has no Combine publisher at all.

The live transport appends parsed samples and sets `pendingPublish` on the
MainActor callback. A single `.common` RunLoop timer at 1/60 s updates the
observed scalar metrics and `visibleSampleRange`; `ForceTraceChart` reads the
stable buffer by index. This preserves the UInt32 wrapping subtraction,
out-of-order rejection, running peak/sum, and the existing 600,000 ms (10
minute) safety cap.

The native deployment floor is now iOS 17 because the Observation macro and
typed environment APIs are iOS 17 APIs. `SendmeterCore` remains iOS 16
compatible. A physical Progressor capture and 30-minute jank/allocation
measurement were not run in this worktree; device performance remains an
explicit follow-up gate.

## Acceptance criteria

- ✅ View-body evaluations bounded at ≤ display rate, independent of BLE rate:
  the timer's fire cadence is the one and only throttle; every pending fire
  publishes; the bench drives the shipped cadence and asserts it is ~60/s
  (58–61 fires over a simulated second), so a wrong cadence fails.
- ✅ No per-notification or per-flush O(window) copy on the live path:
  notifications only append + set `pendingPublish`; the chart indexes the
  accumulator's stable storage from the flushed range.
- ✅ `swift test` stays green (919 tests, 0 failures); hands-free arming
  unaffected (pre-start samples still consumed only by `onWeightSample`); new
  tests cover the scheduler cadence/no-skip, the snapshot branch fields (F8),
  and the window-range slice.
- ✅ Evidence above (deterministic bench at the shipped ~60 Hz cadence, at the
  fake-gauge stream rate; the DEBUG in-app counter reads the same number).

## Original #671 gates

```
cd native/SendmeterNative
swift test                       # 282 tests, 0 failures at #671
xcodegen generate                # OK
xcodebuild -project SendmeterNative.xcodeproj \
  -scheme SendmeterNative \
  -destination 'generic/platform=iOS Simulator' build   # BUILD SUCCEEDED
```
