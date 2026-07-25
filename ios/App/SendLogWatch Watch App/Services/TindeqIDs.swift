import CoreBluetooth
import SendLogWatchCore

/// The Tindeq Progressor's BLE service/characteristic UUIDs. Split out of
/// SendLogWatchCore's TindeqProtocol.swift (issue #191) since CoreBluetooth
/// isn't available outside Apple platforms and the frame parser doesn't need
/// it — only `TindeqManager` does.
extension Tindeq {
    static let service = CBUUID(string: "7E4E1701-1EA6-40C9-9DCC-13D34FFEAD57")
    static let notifyChar = CBUUID(string: "7E4E1702-1EA6-40C9-9DCC-13D34FFEAD57")
    static let controlChar = CBUUID(string: "7E4E1703-1EA6-40C9-9DCC-13D34FFEAD57")
}
