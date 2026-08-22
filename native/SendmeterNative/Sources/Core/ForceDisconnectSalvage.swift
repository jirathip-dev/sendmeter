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
///   * The hands-free persist verdict — `recordingVerdict` in
///     `ios/App/SendLogWatchCore/Sources/SendLogWatchCore/HandsFreeForce.swift`
///     (#682 Guard 1), which the watch's `salvageInterruptedRecording` applies
///     to a hands-free rep even when it ends by a BLE drop.
///   * The note text — the web/watch recovery rows both write
///     "Recovered after connection loss".
///
/// NOTE on "remount recovery": the native app freezes the full force context
/// (`FreePullContext`) on `AppModel` at Start/Arm, so it survives a Force tab
/// remount — unlike the web, whose view-backed `pendingTag`/`pendingSide` can
/// be lost when the drop fires while the view is unmounted. There is therefore
/// no drop-time snapshot fallback here: the LOCK is the single truth for a
/// salvaged rep, and a missing lock resolves to the honest empty attribution.
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

    /// Whether a salvaged rep should be PERSISTED, after the #678-required
    /// parity with the salvageable case re-opened by the reviewer.
    ///
    /// #682 Guard 1 applies to a hands-free rep even when it ends by a BLE
    /// drop instead of an Arm/Stop edge (watch parity): a sub-threshold rep
    /// (peak < `minPeakKg` or duration < `minDurationMs`) is discarded, never
    /// enters the queue, and never reports a durable loss. Manual interrupted
    /// reps are never gated — a manual hold that dies mid-pull is a real rep.
    public static func shouldPersistSalvage(
        wasHandsFree: Bool,
        peakKg: Double,
        durationMs: Double,
        config: HandsFreeForceConfig = .default
    ) -> Bool {
        guard wasHandsFree else { return true }
        return recordingVerdict(peakKg: peakKg, durationMs: durationMs, config: config) == .persist
    }

    /// The tag/side a salvaged rep must persist.
    ///
    /// `locked` is the value captured when the recording STARTED (the web's
    /// locked `pendingTag`/`pendingSide`). The LOCK is the single authority:
    /// a salvaged rep writes exactly the tag/side the user set at recording
    /// start, and never reinterprets a missing side (`.unspecified`) as
    /// `.both` (engineering rule), nor falls back to a display value like
    /// `allTags[0]` or the live pickers (web #298 "never a fallback").
    /// When no lock exists the rep is saved honestly untagged/unspecified —
    /// never something re-derived at save time.
    public static func attribution(locked: Attribution) -> Attribution {
        Attribution(tag: locked.tag, side: locked.side)
    }
}
