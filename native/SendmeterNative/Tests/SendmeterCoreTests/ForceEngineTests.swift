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

    /// #671: publishes are bounded to display rate, independent of the BLE
    /// notification rate. The gate is pure so it is unit-tested here; the
    /// transport runs it from a ~60 Hz flush driver.
    func testPublishCoalescerGatesAtDisplayRate() {
        let coalescer = ForcePublishCoalescer()
        let interval = coalescer.displayIntervalSeconds // ~16.7 ms

        // No time elapsed: nothing to flush yet.
        XCTAssertFalse(coalescer.shouldFlush(now: 0, lastFlush: 0))
        // Just under the interval: still gated.
        XCTAssertFalse(coalescer.shouldFlush(now: interval - 0.001, lastFlush: 0))
        // Exactly at the interval: flush.
        XCTAssertTrue(coalescer.shouldFlush(now: interval, lastFlush: 0))
        // Well past it (e.g. BLE notifications far faster than display): still
        // at most once per interval, never once per notification.
        XCTAssertTrue(coalescer.shouldFlush(now: 10 * interval, lastFlush: 0))
    }

    /// #671 benchmark evidence (deterministic): at the web fake-gauge stream
    /// rate (~12 ms / ~83 Hz, `src/hooks/useTindeq.ts:515-520`) and at a fast
    /// real Progressor batch rate, the coalescer bounds publishes to display
    /// rate (~60 Hz / 16.7 ms). Before this change there was NO gate at all —
    /// one publish (5 @Published assignments + a window array copy) per
    /// notification, i.e. ~83 publishes/sec at the fake-gauge rate.
    func testPublishCoalescerBindsPublishesPerSecondAtStreamRate() {
        let coalescer = ForcePublishCoalescer()

        // Simulate one wall-clock second of notifications.
        func publishesPerSecond(streamIntervalSeconds: Double) -> Int {
            var lastFlush = 0.0
            var flushCount = 0
            var now = 0.0
            while now < 1.0 {
                if coalescer.shouldFlush(now: now, lastFlush: lastFlush) {
                    lastFlush = now
                    flushCount += 1
                }
                now += streamIntervalSeconds
            }
            return flushCount
        }

        // Fake-gauge rate (~83 Hz).
        let atFakeGauge = publishesPerSecond(streamIntervalSeconds: 1.0 / 83.0)
        // A fast Progressor batch rate (~100 Hz).
        let atFastBatches = publishesPerSecond(streamIntervalSeconds: 1.0 / 100.0)

        XCTAssertLessThanOrEqual(atFakeGauge, 60)
        XCTAssertLessThanOrEqual(atFastBatches, 60)
        // Both are bounded to display rate, NOT stream rate.
        XCTAssertLessThan(atFakeGauge, 83)
        XCTAssertLessThan(atFastBatches, 100)
        // The bound holds even when the stream is far faster than the display:
        // a 10x faster stream must NOT scale the publish count 10x (it stays
        // within the same display-rate budget; a few Hz of phase quantization
        // is expected).
        XCTAssertLessThan(atFastBatches, atFakeGauge * 2)
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
