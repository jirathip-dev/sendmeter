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
