import Foundation

/// Durable one-shot visibility for the fire-and-forget gauge-session save
/// path (#287). The individual recordings have their own persistence path,
/// but losing this row leaves them without the History session that groups
/// them. `TindeqManager` may discover that loss after the Force UI is gone,
/// so Home consumes and presents the notice on the next appearance.
enum GaugeSessionLossNotice {
    private static let key = "gaugeSessionSaveLost"

    static func record() {
        UserDefaults.standard.set(true, forKey: key)
    }

    static func consume() -> Bool {
        guard UserDefaults.standard.bool(forKey: key) else { return false }
        UserDefaults.standard.removeObject(forKey: key)
        return true
    }
}
