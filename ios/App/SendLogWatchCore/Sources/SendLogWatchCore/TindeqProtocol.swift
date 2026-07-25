import Foundation

/// Tindeq Progressor BLE protocol — direct port of the web app's
/// src/lib/tindeq-protocol.ts. Pure parsing, no BLE objects. The
/// service/characteristic CBUUIDs live in the app target's TindeqIDs.swift
/// (an extension on this enum) since CoreBluetooth isn't available outside
/// Apple platforms and isn't needed for parsing.
public enum Tindeq {
    public static let namePrefix = "Progressor"

    public enum Cmd: UInt8 {
        case tare = 0x64
        case startWeight = 0x65
        case stop = 0x66
        case sampleBattery = 0x6F
    }
}

public enum TindeqFrame: Equatable, Sendable {
    case weight([WeightSample])
    case response(Data)
    case lowBattery
    case unknown(UInt8)

    public struct WeightSample: Equatable, Sendable {
        public let us: UInt32  // device timestamp, microseconds
        public let kg: Float
    }
}

/// Frames are [tag u8][length u8][payload]. Weight payload (tag 0x01) is
/// repeated pairs of (float32 LE kg, uint32 LE µs).
public func parseTindeqNotification(_ data: Data) -> TindeqFrame {
    guard data.count >= 2 else { return .unknown(0xFF) }
    let tag = data[data.startIndex]
    let len = Int(data[data.startIndex + 1])

    switch tag {
    case 0x01:
        let payload = data.dropFirst(2)
        let pairCount = min(len, payload.count) / 8
        var samples: [TindeqFrame.WeightSample] = []
        samples.reserveCapacity(pairCount)
        payload.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for i in 0..<pairCount {
                let kg = Float(bitPattern: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: i * 8, as: UInt32.self)))
                let us = UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: i * 8 + 4, as: UInt32.self))
                samples.append(.init(us: us, kg: kg))
            }
        }
        return .weight(samples)
    case 0x00:
        return .response(Data(data.dropFirst(2)))
    case 0x02:
        return .lowBattery
    default:
        return .unknown(tag)
    }
}
