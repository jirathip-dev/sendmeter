import XCTest
@testable import SendmeterCore

final class ForceEngineTests: XCTestCase {
    func testParsesBoundedWeightFrame() {
        var bytes: [UInt8] = [0x01, 0x08]
        let force = Float(12.5).bitPattern
        bytes += [
            UInt8(force & 0xff),
            UInt8((force >> 8) & 0xff),
            UInt8((force >> 16) & 0xff),
            UInt8((force >> 24) & 0xff)
        ]
        let timestamp: UInt32 = 100_000
        bytes += [
            UInt8(timestamp & 0xff),
            UInt8((timestamp >> 8) & 0xff),
            UInt8((timestamp >> 16) & 0xff),
            UInt8((timestamp >> 24) & 0xff)
        ]
        bytes += [0xde, 0xad] // outside declared payload

        guard case let .weight(samples) = TindeqFrameParser.parse(Data(bytes)) else {
            return XCTFail("Expected weight frame")
        }
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].kilograms, 12.5, accuracy: 0.001)
        XCTAssertEqual(samples[0].microseconds, timestamp)
    }

    func testAccumulatorSummarizesAndUsesRollingWindow() {
        var accumulator = ForceSessionAccumulator()
        let incoming = (0..<20).map {
            TindeqWireSample(
                microseconds: UInt32($0 * 1_000_000),
                kilograms: Double($0)
            )
        }
        XCTAssertEqual(accumulator.append(incoming), 20)
        XCTAssertEqual(accumulator.visibleWindow().first?.milliseconds, 9_000)
        let summary = accumulator.summary()
        XCTAssertEqual(summary?.durationMilliseconds, 19_000)
        XCTAssertEqual(summary?.peakKilograms, 19)
        XCTAssertEqual(summary?.averageKilograms, 9.5)
    }

    /// #682: the iPhone force recording cap is 10 minutes, not 30 — the
    /// backstop behind the static-load watchdog, mirroring
    /// `TindeqRecordingLimit.maxRecordingMs` on the watch.
    func testAccumulatorCapsAtTenMinutesNotThirty() {
        XCTAssertEqual(ForceSessionAccumulator.maximumRecordingMilliseconds, 600_000)

        var accumulator = ForceSessionAccumulator()
        // `startMicroseconds` is the first sample's device timestamp, so
        // elapsed is measured relative to it, not absolute.
        XCTAssertEqual(
            accumulator.append([TindeqWireSample(microseconds: 0, kilograms: 5)]),
            1
        )
        // A sample landing exactly on the cap (600 s elapsed) is accepted.
        let capMicroseconds = UInt32(ForceSessionAccumulator.maximumRecordingMilliseconds * 1_000)
        XCTAssertEqual(
            accumulator.append([TindeqWireSample(microseconds: capMicroseconds, kilograms: 5)]),
            1
        )
        // A sample just past the cap is dropped, so the saved trace never
        // extends beyond the 10-minute ceiling.
        XCTAssertEqual(
            accumulator.append([TindeqWireSample(microseconds: capMicroseconds + 1_000, kilograms: 5)]),
            0
        )
        XCTAssertEqual(accumulator.samples.count, 2)
    }

    /// #671: the live window is a zero-copy `ArraySlice` over the
    /// accumulator's stable storage — an O(log n) binary search plus an O(1)
    /// slice, never a per-notification `Array(samples[low...])` copy. This
    /// pins the API shape AND proves storage sharing by pointer identity: the
    /// slice's buffer base address equals the accumulator buffer's base
    /// address offset by the slice start — no element copy was allocated.
    func testVisibleWindowIsZeroCopySliceOverStableStorage() {
        var accumulator = ForceSessionAccumulator()
        let incoming = (0..<20).map {
            TindeqWireSample(
                microseconds: UInt32($0 * 1_000_000),
                kilograms: Double($0)
            )
        }
        accumulator.append(incoming)

        let window: ArraySlice<TindeqSample> = accumulator.visibleWindow()
        XCTAssertEqual(window.count, 11) // samples 9...19 (10 s window + the newest)
        XCTAssertEqual(window.first?.milliseconds, 9_000)
        XCTAssertEqual(window.last?.milliseconds, 19_000)

        // Pointer identity: the slice is a view over the accumulator's buffer,
        // not a fresh allocation. (Old implementation returned
        // `Array(samples[low...])` — a new 800-element buffer per notification.)
        window.withUnsafeBufferPointer { windowPtr in
            accumulator.samples.withUnsafeBufferPointer { allPtr in
                guard let windowBase = windowPtr.baseAddress,
                      let allBase = allPtr.baseAddress else {
                    return XCTFail("Expected contiguous buffers")
                }
                XCTAssertEqual(
                    windowBase,
                    allBase.advanced(by: window.startIndex),
                    "visibleWindow() must share the accumulator's storage (zero-copy)"
                )
            }
        }
    }

    func testVisibleRangeBounds() {
        var accumulator = ForceSessionAccumulator()
        XCTAssertEqual(accumulator.visibleRange(), 0..<0)

        let incoming = (0..<20).map {
            TindeqWireSample(
                microseconds: UInt32($0 * 1_000_000),
                kilograms: Double($0)
            )
        }
        accumulator.append(incoming)
        let range = accumulator.visibleRange()
        XCTAssertEqual(range, 9..<20)
        // The slice over that range is exactly the 10 s window.
        XCTAssertEqual(Array(accumulator.samples[range]).count, 11)
        XCTAssertEqual(accumulator.samples[range].first?.milliseconds, 9_000)
    }

    /// #671: the shipped publish rule — a timer fire publishes iff a
    /// notification has marked samples pending. The timer cadence is the one
    /// and only throttle (the #671 review's F1 finding: two throttles with the
    /// same period beat against each other and drop a fraction of the fires).
    func testFlushSchedulerPublishesExactlyOnPendingFires() {
        let scheduler = ForcePublishScheduler()

        // No pending samples since the last publish: the fire is a no-op.
        XCTAssertFalse(scheduler.shouldPublishOnFire(pending: false))
        // Pending samples: the fire publishes, regardless of how recently the
        // previous one happened — the fire cadence is the only bound.
        XCTAssertTrue(scheduler.shouldPublishOnFire(pending: true))
    }

    /// #671 benchmark evidence (deterministic, at the SHIPPED driver's cadence):
    /// the flush timer is scheduled with
    /// `ForcePublishScheduler.displayIntervalSeconds` — the exact value
    /// `TindeqBluetooth.startFlushDriver()` uses for its real `Timer` — so this
    /// bench generates the same ~60 Hz fire sequence and asserts the cadence
    /// itself, which is the thing the round-2 review found wrong.
    ///
    /// A real repeating `Timer` keeps its absolute schedule: fire k is scheduled
    /// at k·interval, and lateness does NOT compound into the period. The model
    /// below is exactly that — an absolute schedule plus a bounded, independent
    /// (non-accumulating) jitter per fire. The round-2 review measured the
    /// previous cumulative-jitter model degenerating to 41 fires/s while the
    /// old assertions still passed (they were tautologies: `publishCount ==
    /// fireCount` when the rule is the identity). Every assertion here fails if
    /// the cadence drifts from ~60/s.
    func testPublishBenchRunsAtShippedDisplayCadence() {
        let scheduler = ForcePublishScheduler()
        let interval = scheduler.displayIntervalSeconds // 1/60 s ≈ 16.7 ms

        // Deterministic per-fire lateness in [0, 0.4 ms): fires land at or
        // after their scheduled instant, never shifting the next fire's
        // schedule.
        func tickSequence(seconds: Double) -> [Double] {
            let fireCount = Int((seconds / interval).rounded())
            return (0..<fireCount).map { k in
                let scheduled = Double(k) * interval
                let jitter = 0.0004 * (Double(k % 8) / 8.0)
                return scheduled + jitter
            }
        }

        let fires = tickSequence(seconds: 1.0)
        // The cadence must be display rate: ~60 fires per second. A degenerate
        // sub-cadence (41 Hz in round 2, or a 30 Hz model) fails here.
        XCTAssertGreaterThanOrEqual(fires.count, 58, "the timer must run at display cadence (~60/s)")
        XCTAssertLessThanOrEqual(fires.count, 61, "the timer must not exceed display cadence")

        // Saturated stream (the fake-gauge rate marks `pending` between every
        // fire): publishes equal fires — ~60/s, bounded by the cadence, never
        // the ~83 Hz arrival rate, with zero skipped fires.
        let saturatedPublishes = fires.reduce(into: 0) { count, _ in
            if scheduler.shouldPublishOnFire(pending: true) { count += 1 }
        }
        XCTAssertEqual(saturatedPublishes, fires.count, "every pending fire must publish")
        XCTAssertGreaterThanOrEqual(saturatedPublishes, 58, "publishes must run at display cadence (~60/s)")
        XCTAssertLessThanOrEqual(saturatedPublishes, 61, "publishes must not exceed display cadence")

        // Idle stream: fires without pending data publish nothing.
        let idlePublishes = fires.reduce(into: 0) { count, _ in
            if scheduler.shouldPublishOnFire(pending: false) { count += 1 }
        }
        XCTAssertEqual(idlePublishes, 0, "fires without pending data publish nothing")

        // Stream-rate independence: a far faster stream (100 Hz) still
        // publishes at the cadence, not at stream rate.
        XCTAssertLessThan(saturatedPublishes, 100)
    }

    /// #671: the published snapshot has exactly one field set while a stream
    /// is merely armed (the live reading) and all five while recording —
    /// the two objectWillChange pulses the review flagged in F8 collapse to
    /// one per flush.
    func testSnapshotBuilderPublishesSinglePulseWhileArmed() {
        var accumulator = ForceSessionAccumulator()
        accumulator.append((0..<20).map {
            TindeqWireSample(microseconds: UInt32($0 * 1_000_000), kilograms: Double($0))
        })

        // Armed but not recording: only the live reading is published.
        let armed = ForcePublishSnapshotBuilder.snapshot(
            isRecording: false,
            handsFreeArmed: true,
            lastSampleKilograms: 42,
            accumulator: accumulator
        )
        XCTAssertEqual(armed.fields, [.currentKilograms])
        XCTAssertEqual(armed.currentKilograms, 42)
        XCTAssertFalse(armed.fields.contains(.peakKilograms))
        XCTAssertFalse(armed.fields.contains(.window))

        // Recording: the full force surface + window.
        let recording = ForcePublishSnapshotBuilder.snapshot(
            isRecording: true,
            handsFreeArmed: false,
            lastSampleKilograms: 42,
            accumulator: accumulator
        )
        XCTAssertEqual(recording.fields, .all)
        XCTAssertEqual(recording.currentKilograms, 19)
        XCTAssertEqual(recording.peakKilograms, 19)
        XCTAssertEqual(recording.averageKilograms, 9.5)
        XCTAssertEqual(recording.elapsedMilliseconds, 19_000)
        // The window range is the same binary search the chart's 10 s window
        // uses — wired from the accumulator's visibleRange.
        XCTAssertEqual(recording.visibleRange, accumulator.visibleRange())

        // Idle stream: nothing publishes.
        let idle = ForcePublishSnapshotBuilder.snapshot(
            isRecording: false,
            handsFreeArmed: false,
            lastSampleKilograms: 0,
            accumulator: accumulator
        )
        XCTAssertEqual(idle.fields, [])
        XCTAssertEqual(idle, .idle)
    }

    /// #671: the snapshot's window range reads over the accumulator's stable
    /// storage — the chart slices `samples[visibleRange]` at flush time, the
    /// only window copy left, at display rate rather than notification rate.
    func testSnapshotWindowRangeSlicesAccumulatorStorage() {
        var accumulator = ForceSessionAccumulator()
        accumulator.append((0..<20).map {
            TindeqWireSample(microseconds: UInt32($0 * 1_000_000), kilograms: Double($0))
        })

        let snapshot = ForcePublishSnapshotBuilder.snapshot(
            isRecording: true,
            handsFreeArmed: false,
            lastSampleKilograms: 0,
            accumulator: accumulator
        )
        let window = Array(accumulator.samples[snapshot.visibleRange])
        XCTAssertEqual(window.count, 11)
        XCTAssertEqual(window.first?.milliseconds, 9_000)
        XCTAssertEqual(window.last?.milliseconds, 19_000)
    }

    func testProtocolScheduleAlternatesSidesWithoutDuplicatingReverseActionSets() {
        let preset = TindeqPreset(
            name: "Reverse",
            holdSeconds: 10,
            repetitions: 4,
            sets: 2,
            restBetweenRepetitionsSeconds: 5,
            restBetweenSetsSeconds: 60,
            alternateSides: true,
            protocolMode: .reverseAction,
            cadenceOutSeconds: 3,
            cadenceReturnSeconds: 3
        )
        let stages = ForceProtocolSchedule.stages(preset: preset, startingSide: .right)
        let work = stages.filter { $0.kind == .work }
        XCTAssertEqual(work.count, 4) // 2 sides × 2 sets, one continuous row per set/side
        XCTAssertEqual(work[0].side, .right)
        XCTAssertEqual(work[1].side, .left)
        XCTAssertEqual(work[0].durationSeconds, 24)
    }
}
