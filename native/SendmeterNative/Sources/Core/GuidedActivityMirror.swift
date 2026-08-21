import Foundation

/// The lock-screen mirror for a guided protocol run, as a pure Core value.
///
/// The mirror owns the state the app process banks that the widget cannot
/// derive — the protocol's schedule/content and the hold-end peak — and
/// derives EVERY snapshot from the `ForceProtocolRun` handed in at call time.
/// It deliberately never stores a run: `ForceProtocolRun` is a struct, and a
/// copy cached across a stage transition freezes the card on the stale stage
/// (#674 review N1 — the previous manager held `self.run` and pushed the
/// same stage-0 snapshot for the entire protocol). The call site (the
/// `@State` run in `GuidedForceProtocolView`) is the single live source of
/// run state; this mirror only reads the value passed to `snapshot(run:at:)`.
///
/// Living in Core makes the contract testable: a test can build a mirror,
/// advance a local `var run` across stages, and assert the snapshot tracks
/// the run's CURRENT stage — the exact failure the old wiring hid behind the
/// `Sources/App` boundary that `swift test` never compiles.
public struct GuidedActivityMirror: Sendable {
    public let content: GuidedProtocolActivityContent
    public private(set) var peakKilograms: Double?

    public init(content: GuidedProtocolActivityContent, peakKilograms: Double? = nil) {
        self.content = content
        self.peakKilograms = peakKilograms
    }

    /// Bank the hold-end peak (manager-owned state, independent of the run).
    public mutating func bankPeak(_ kilograms: Double?) {
        peakKilograms = kilograms
    }

    /// Everything the lock screen needs at one instant, derived from the LIVE
    /// run passed in. The anchor is built here from `run.currentStage` +
    /// `stageStartedAt`, so Skip Stage advances and the terminal complete
    /// stage are reflected immediately (#674 review F3/F5).
    public func snapshot(
        run: ForceProtocolRun,
        at date: Date = Date(),
        isPaused: Bool? = nil
    ) -> GuidedProtocolActivityContent.Snapshot {
        let anchor = GuidedProtocolActivityContent.RunAnchor(run: run, at: date, isPaused: isPaused)
        return content.snapshot(runAnchor: anchor, peakKilograms: peakKilograms)
    }
}
