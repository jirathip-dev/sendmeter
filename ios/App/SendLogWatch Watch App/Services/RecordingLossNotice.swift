import Foundation

/// Durable one-shot visibility for a Tindeq recording that genuinely could
/// not be kept (#486, CLAUDE.md #264 — "a recording that can't be persisted
/// is reported, never swallowed"): `PendingRecordingQueue.enqueue` returning
/// `.lost` means BOTH disk persistence and the in-memory direct-upload
/// fallback failed — the sample buffer is gone. `saveStop()`/
/// `salvageInterruptedRecording()` may discover that after the Force UI has
/// moved on (an unplanned BLE drop can fire the salvage path with nobody
/// watching the screen), mirroring `GaugeSessionLossNotice`, so Home consumes
/// and presents the notice on the next appearance rather than relying on a
/// toast nobody was looking at.
enum RecordingLossNotice {
    private static let key = "tindeqRecordingSaveLost"

    static func record() {
        UserDefaults.standard.set(true, forKey: key)
    }

    static func consume() -> Bool {
        guard UserDefaults.standard.bool(forKey: key) else { return false }
        UserDefaults.standard.removeObject(forKey: key)
        return true
    }
}
