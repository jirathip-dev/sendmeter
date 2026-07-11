import XCTest
@testable import SendLogWatch

final class TindeqProtocolTests: XCTestCase {
    /// Build a weight frame: [0x01][len][(float32 LE kg, uint32 LE µs) * n]
    private func weightFrame(_ pairs: [(kg: Float, us: UInt32)]) -> Data {
        var data = Data([0x01, UInt8(pairs.count * 8)])
        for p in pairs {
            withUnsafeBytes(of: p.kg.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: p.us.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    func testParsesSingleWeightSample() {
        let frame = weightFrame([(kg: 23.5, us: 1_000_000)])
        guard case .weight(let samples) = parseTindeqNotification(frame) else {
            return XCTFail("expected weight frame")
        }
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].kg, 23.5, accuracy: 0.001)
        XCTAssertEqual(samples[0].us, 1_000_000)
    }

    func testParsesMultipleSamplesPerNotification() {
        let frame = weightFrame([
            (kg: 10.0, us: 0),
            (kg: 12.25, us: 12_500),
            (kg: 14.5, us: 25_000),
        ])
        guard case .weight(let samples) = parseTindeqNotification(frame) else {
            return XCTFail("expected weight frame")
        }
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples[1].kg, 12.25, accuracy: 0.001)
        XCTAssertEqual(samples[2].us, 25_000)
    }

    func testLowBatteryFrame() {
        XCTAssertEqual(parseTindeqNotification(Data([0x02, 0x00])), .lowBattery)
    }

    func testResponseFrame() {
        let frame = Data([0x00, 0x02, 0xAB, 0xCD])
        guard case .response(let payload) = parseTindeqNotification(frame) else {
            return XCTFail("expected response frame")
        }
        XCTAssertEqual(payload, Data([0xAB, 0xCD]))
    }

    func testTruncatedFrameIsSafe() {
        XCTAssertEqual(parseTindeqNotification(Data([0x01])), .unknown(0xFF))
        // Length byte claims more than actually present — parse what's there
        var frame = Data([0x01, 0x10])
        frame.append(contentsOf: [UInt8](repeating: 0, count: 8))
        guard case .weight(let samples) = parseTindeqNotification(frame) else {
            return XCTFail("expected weight frame")
        }
        XCTAssertEqual(samples.count, 1)
    }

    func testUnknownTag() {
        XCTAssertEqual(parseTindeqNotification(Data([0x7F, 0x00])), .unknown(0x7F))
    }
}
