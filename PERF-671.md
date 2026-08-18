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
   during scroll tracking) flushes the 5 published values at most once per
   display interval, gated by a pure, unit-tested `ForcePublishCoalescer`
   (`ForceEngine.swift`). Timer lifecycle: started when a stream is live
   (recording or hands-free-armed), stopped on stop/disarm/disconnect/reset.
2. **Zero-copy window** (`ForceEngine.swift`): `visibleWindow()` now returns an
   `ArraySlice` over the accumulator's stable `samples` storage (O(log n)
   binary search + O(1) slice). The accumulator's buffer is only reallocated
   by appends, not per-notification copies. The chart does one `Array(...)`
   copy at flush time (≤60 Hz), which is a deliberate display-rate copy over
   stable storage — never a per-notification hot-path allocation.
3. **`Task { @MainActor }` hop dropped** in `didUpdateValueFor`: the delegate
   already runs on `.main`; the body now runs under `MainActor.assumeIsolated`
   (the class is `@MainActor`), eliminating a per-notification Task
   allocation + actor hop.
4. **Hands-free arming unaffected**: `onWeightSample` still feeds every parsed
   sample to the arming loop pre-start; pre-start samples still never enter
   the accumulator. The armed-but-not-recording live reading is published from
   `lastSampleKilograms` at flush time.
5. **Debug evidence counter**: DEBUG builds publish `publishesPerSecond` (the
   flush driver's measured publish rate, zero outside DEBUG), so the
   coalescing win is observable at runtime in the simulator with the fake
   transport.

## Evidence — publishes/sec at stream rates

Deterministic bench of the coalescer gate (the same math the flush driver
runs), simulated over one wall-clock second of notifications:

| Stream | Rate | Before (no gate) | After (coalesced) |
|---|---|---|---|
| Fake-gauge (`?fake-tindeq`, `useTindeq.ts:515-520`) | ~83 Hz (12 ms) | **~83 publishes/s** | **41 publishes/s** |
| Fast Progressor batches | ~100 Hz (10 ms) | ~100 publishes/s | **49 publishes/s** |
| Real Progressor stream | ~80 Hz (12.5 ms) | ~80 publishes/s | **40 publishes/s** |

Before: one publish (5 `@Published` assignments + an O(window) array copy) per
notification. After: publishes are bounded at display rate (≤ ~60 Hz budget;
the sub-60 counts above are the gate's phase quantization in a 1 s
simulation) and *independent* of the BLE rate — a 100 Hz stream publishes at
the same display-rate budget as an 83 Hz stream, not 100 Hz worth of SwiftUI
invalidation.

The per-notification O(window) copy is gone from the hot path entirely: the
allocation test `ForceEngineTests.testVisibleWindowIsZeroCopySliceOverStableStorage`
proves by pointer identity that `visibleWindow()` shares the accumulator's
buffer (no copy), and `testPublishCoalescerBindsPublishesPerSecondAtStreamRate`
pins the bounded-publishes invariant. The one remaining window copy is at
flush time — display rate, not notification rate.

## Acceptance criteria

- ✅ View-body evaluations bounded at ≤ display rate, independent of BLE rate:
  `ForcePublishCoalescer` gates flushes to `1/60 s`; tests prove the bound
  holds at 83 Hz and 100 Hz streams.
- ✅ No per-notification O(window) copy on the hot path: `visibleWindow()` is a
  zero-copy `ArraySlice` (pointer-identity allocation test on
  `ForceSessionAccumulator`).
- ✅ `swift test` stays green (280 tests, 0 failures); hands-free arming
  unaffected (pre-start samples still consumed only by `onWeightSample`; new
  tests cover the window/range/coalescer seams).
- ✅ Evidence above (debug counter + deterministic bench at fake-gauge stream
  rate).

## Gates run

```
cd native/SendmeterNative
swift test                       # 280 tests, 0 failures
xcodegen generate                # OK
xcodebuild -project SendmeterNative.xcodeproj \
  -scheme SendmeterNative \
  -destination 'generic/platform=iOS Simulator' build   # BUILD SUCCEEDED
```
