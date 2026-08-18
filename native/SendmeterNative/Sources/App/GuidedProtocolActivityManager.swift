import ActivityKit
import Foundation
import SendmeterCore

/// Lock-screen Live Activity for the guided force protocol (#628) — the
/// native equivalent of the web's `src/lib/liveActivity.ts` + the
/// `sendlog-live-activity` plugin's Tindeq activity.
///
/// The pure content model + countdown mapping live in SendmeterCore
/// (`GuidedActivityContent`); this manager is the thin ActivityKit adapter:
/// it starts the activity from the run's already-computed schedule, rebuilds
/// the snapshot ONLY on state transitions (stage changes, hold-end peak) and
/// ends it when the protocol ends. The lock screen renders its countdown
/// natively from the segment window (`Text(timerInterval:)`), so there are
/// never per-tick updates — exactly the web's contract.
///
/// KEEP-IN-SYNC note: unlike the web (which duplicates `ActivityModels.swift`
/// across its widget and plugin targets), the app and the widget extension
/// compile the SAME `GuidedActivityContent` from SendmeterCore and the SAME
/// `GuidedProtocolActivityAttributes` from `Sources/Shared` (single source
/// file, two targets, one XcodeGen project), so the ActivityKit
/// `Attributes`/`ContentState` shape cannot drift between them — keep it that
/// way: the widget must consume the Core model, never a copied one, and the
/// wire type must stay in `Sources/Shared`, never duplicated.
///
/// Live Activities do not run in the simulator's gallery — device-only to
/// verify; every failure here is swallowed so the protocol itself is never
/// affected.
@MainActor
public final class GuidedProtocolActivityManager {
    private var activity: Activity<GuidedProtocolActivityAttributes>?
    private var content: GuidedProtocolActivityContent?
    private var peakKilograms: Double?

    public init() {}

    public var isActive: Bool { activity != nil }

    /// Start a lock-screen activity mirroring this protocol run. No-op when
    /// one is already active or Live Activities are unavailable.
    public func start(
        run: ForceProtocolRun,
        preset: TindeqPreset,
        targetPlan: ForceTargetPlan,
        fallbackSide: TindeqSide
    ) {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = GuidedProtocolActivityContent.from(
            run: run,
            preset: preset,
            targetPlan: targetPlan,
            fallbackSide: fallbackSide,
            start: Date()
        )
        self.content = content
        peakKilograms = nil
        guard let snapshot = content.snapshot(
            atEpochMs: Date().timeIntervalSince1970 * 1_000
        ) else { return }
        do {
            let attributes = GuidedProtocolActivityAttributes(presetID: preset.id, runID: run.runID)
            let state = makeContentState(snapshot)
            let initial = ActivityContent(
                state: state,
                staleDate: state.segmentEnd
            )
            activity = try Activity.request(
                attributes: attributes,
                content: initial,
                pushType: nil
            )
        } catch {
            activity = nil
            self.content = nil
        }
    }

    /// Rebuild the snapshot at the current instant — called on every stage
    /// transition, never on a tick.
    public func refresh() {
        guard activity != nil else { return }
        pushSnapshot()
    }

    /// Bank the hold's final peak on the card (called when a work stage
    /// ends).
    public func updatePeak(_ kilograms: Double?) {
        peakKilograms = kilograms
        pushSnapshot()
    }

    /// Take the activity down. `immediate` for protocol end/cancel; a
    /// lingering dismissal would show a stale card for the system's default
    /// window.
    public func end(immediate: Bool = true) {
        guard let activity else { return }
        self.activity = nil
        content = nil
        peakKilograms = nil
        Task {
            await activity.end(
                nil,
                dismissalPolicy: immediate ? .immediate : .default
            )
        }
    }

    private func pushSnapshot() {
        guard let content,
              let snapshot = content.snapshot(
                  atEpochMs: Date().timeIntervalSince1970 * 1_000,
                  peakKilograms: peakKilograms
              ),
              let activity
        else { return }
        let state = makeContentState(snapshot)
        let updated = ActivityContent(state: state, staleDate: state.segmentEnd)
        Task {
            await activity.update(updated)
        }
    }

    private func makeContentState(_ snapshot: GuidedProtocolActivityContent.Snapshot) -> GuidedProtocolActivityAttributes.ContentState {
        GuidedProtocolActivityAttributes.ContentState(
            title: snapshot.title,
            phase: snapshot.phaseToken,
            phaseLabel: snapshot.phaseLabel,
            detailLabel: snapshot.detailLabel,
            segmentStart: Date(timeIntervalSince1970: snapshot.segmentStartEpochMs / 1_000),
            segmentEnd: Date(timeIntervalSince1970: snapshot.segmentEndEpochMs / 1_000),
            progress: snapshot.progress,
            peakKilograms: snapshot.peakKilograms,
            targetKilograms: snapshot.targetKilograms
        )
    }
}
