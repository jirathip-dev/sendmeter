import Foundation
import SendLogWatchCore

/// #678: the native disconnect-salvage rule set, kept pure so `swift test`
/// can prove the web #298 "locked tag/side" rule and the salvage gate without
/// a CoreBluetooth stack. The AppModel `.interrupted` handler drives this.
///
/// KEEP-IN-SYNC:
///   * The salvage GATE — `TindeqSalvagePolicy.shouldSalvage` in
///     `ios/App/SendLogWatchCore/Sources/SendLogWatchCore/TindeqSalvagePolicy.swift`.
///   * The locked tag/side attribution — the web's `src/hooks/useTindeq.ts`
///     `InterruptionContext` / `recoveredTagSide` and `gaugeInputLock.ts`
///     (#119 / #298 round 5), and the watch's
///     `TindeqManager.salvageInterruptedRecording`.
///   * The note text — the web/watch recovery rows both write
///     "Recovered after connection loss".
public enum ForceDisconnectSalvage {
    /// The tag/side a salvaged rep persists — what the user actually set at
    /// recording start, never a re-derived fallback (web #298).
    public struct Attribution: Equatable, Sendable {
        public let tag: String
        public let side: TindeqSide

        public init(tag: String, side: TindeqSide) {
            self.tag = tag
            self.side = side
        }

        public static let empty = Attribution(tag: "", side: .unspecified)
    }

    /// The note a salvaged rep carries so it reads identically to the web and
    /// watch recovery rows in History.
    public static let recoveredNote = "Recovered after connection loss"

    /// The durable-loss reason a failed salvage writes through
    /// `LostRecordingStore`, so a salvage failure is reported as its own kind
    /// and not conflated with an ordinary recording save.
    public static let lossReason = "recording-salvage"

    /// Whether an unplanned BLE drop mid-hold should salvage the in-flight rep
    /// as its own recording. Delegates to the watch's pure gate so the two
    /// targets can never drift.
    public static func shouldSalvage(
        wasIntentional: Bool,
        wasMeasuring: Bool,
        sampleCount: Int
    ) -> Bool {
        TindeqSalvagePolicy.shouldSalvage(
            wasIntentional: wasIntentional,
            wasMeasuring: wasMeasuring,
            sampleCount: sampleCount
        )
    }

    /// Resolve the tag/side a salvaged rep must persist.
    ///
    /// `locked` is the value captured when the recording STARTED (the web's
    /// locked `pendingTag`/`pendingSide`). The LOCK is the single authority:
    /// a salvaged rep writes exactly the tag/side the user set at recording
    /// start, and never reinterprets a missing side (`.unspecified`) as
    /// `.both` (engineering rule), nor falls back to a display value like
    /// `allTags[0]` (web #298 "never a fallback").
    ///
    /// `droppedSnapshot` is only a remount-recovery fallback for a missing
    /// TAG — the web's `recoveredTagSide` snapshots the label at DROP time
    /// (`interruptionContext`), and a fresh ForceView that remounts after the
    /// drop has not seeded its own pendingTag yet (web #117). The side is
    /// never taken from the snapshot, because the lock already holds it.
    public static func attribution(
        locked: Attribution,
        droppedSnapshot: Attribution? = nil
    ) -> Attribution {
        Attribution(
            tag: locked.tag.isEmpty ? (droppedSnapshot?.tag ?? "") : locked.tag,
            side: locked.side
        )
    }
}
