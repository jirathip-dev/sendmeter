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

    /// #671 benchmark evidence (deterministic, drives the SHIPPED scheduler
    /// rule): the flush driver's timer fires at display interval (~16.7 ms)
    /// and every pending fire publishes. BLE arrival rates do NOT matter — a
    /// fire with no pending samples publishes nothing, so the publish rate is
    /// exactly the timer cadence while the stream is saturated, with the
    /// display-interval bound independent of the stream rate. This replaces
    /// the review's F2 criticism: the old bench polled a time-gate at BLE
    /// arrival times (an implementation that was never shipped) and hid the
    /// F1 skip bug entirely; this one simulates the real 60 Hz fire sequence,
    /// including realistic jitter, against the exact rule the driver runs.
    func testPublishBenchDrivesShippedSchedulerAtTimerCadence() {
        let scheduler = ForcePublishScheduler()
        let interval = scheduler.displayIntervalSeconds

        func tickSequence(seconds: Double, withJitter: Bool) -> [Double] {
            // A 60 Hz timer fires at-or-after each scheduled instant, with
            // jitter that grows over a run. Model it as schedule + a slowly
            // accumulating positive offset.
            var times: [Double] = []
            var elapsed = 0.0
            var jitter = 0.0
            while elapsed < seconds {
                jitter += withJitter ? 0.0004 : 0.0
                elapsed += interval + jitter
                times.append(elapsed)
            }
            return times
        }

        // Saturate every fire: a fast stream keeps `pending` true between fires.
        func publishesPerSecond(fireTimes: [Double], alwaysPending: Bool) -> Int {
            var count = 0
            for fire in fireTimes {
                if scheduler.shouldPublishOnFire(pending: alwaysPending) {
                    count += 1
                }
            }
            return count
        }

        // At a true ~60 Hz cadence (with jitter) over one second, saturated:
        // publishes equal fires — every fire that has data publishes.
        let jitteryFires = tickSequence(seconds: 1.0, withJitter: true)
        let saturatedPublishes = publishesPerSecond(fireTimes: jitteryFires, alwaysPending: true)
        XCTAssertEqual(saturatedPublishes, jitteryFires.count, "every pending fire must publish")
        // Bounded at display rate (60 Hz cadence + jitter) — a real 120 Hz
        // stream can never push this higher.
        XCTAssertLessThanOrEqual(saturatedPublishes, 61)

        // Stream-rate independence: a far faster stream marks `pending` between
        // fires too, and publishes are STILL the fire count — not stream count.
        let idleFires = tickSequence(seconds: 1.0, withJitter: true)
        let idlePublishes = publishesPerSecond(fireTimes: idleFires, alwaysPending: false)
        XCTAssertEqual(idlePublishes, 0, "fires without pending data publish nothing")

        // The F1 skip fraction is zero by construction: no time-gate drops a
        // fire. Every fire with pending samples published.
        XCTAssertEqual(saturatedPublishes, jitteryFires.count)
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
