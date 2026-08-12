import Foundation

/// SL-584 / #590 review F1: the unified Force finish control's confirm runs
/// `logSessionNow()` + `disconnect()`, and `disconnect()` discards an
/// in-flight rep claim AND marks the disconnect intentional, which also
/// suppresses the BLE-loss salvage path. With hands-free armed, a pull can
/// start a rep while the confirmation card is covering the live gauge (the
/// card is attached at body level), so an unguarded confirm would silently
/// destroy the rep being recorded — a loss the old finish control (which
/// only logged, never disconnected) could not cause.
///
/// Two layers, both decided HERE so every interleaving is unit-testable and
/// the view stays a thin pass-through (the #476 seam pattern):
/// 1. `shouldDismissConfirmation` — an OPEN confirmation must dismiss the
///    moment recording starts: a live pull means the user is not done.
/// 2. `mayExecuteFinish` — a confirm tap that races that dismissal by
///    landing in the same instant must execute nothing. The rep always
///    wins; the user re-taps the flag after the rep completes.
///
/// A save in flight deliberately does NOT block the finish:
/// `logSessionNow()` already defers itself behind in-flight saves
/// (`finishAfterSaves`) and the disconnect does not orphan a saving rep —
/// verified in #590's review — so gating on `isSaving` here would only
/// silently swallow taps the pipeline handles correctly.
public enum ForceFinishPolicy {
    public static func shouldDismissConfirmation(isMeasuring: Bool) -> Bool {
        isMeasuring
    }

    public static func mayExecuteFinish(isMeasuring: Bool) -> Bool {
        !isMeasuring
    }
}
