import Foundation

/// Whether an unplanned BLE drop mid-hold should salvage the in-flight rep
/// as its own recording, same as a "Save now" (issue #151). Pure so
/// it's unit-testable without a CoreBluetooth stack — see
/// `TindeqManager.centralManager(_:didDisconnectPeripheral:)`.
public enum TindeqSalvagePolicy {
    public static func shouldSalvage(wasIntentional: Bool, wasMeasuring: Bool, sampleCount: Int) -> Bool {
        !wasIntentional && wasMeasuring && sampleCount >= 2
    }
}
