import ActivityKit
import Foundation
import SendmeterCore

/// Lock-screen Live Activity for the guided force protocol (#628) — the
/// native equivalent of the web's `src/lib/liveActivity.ts` + the
/// `sendlog-live-activity` plugin's Tindeq activity.
///
/// The pure content model + countdown mapping live in SendmeterCore
/// (`GuidedActivityContent`); this manager is the thin ActivityKit adapter:
/// it starts the activity with the run's schedule and pushes the snapshot
/// ONLY on state transitions (stage changes, hold-end peak, Skip Stage, run
/// complete) and ends it when the protocol ends. The lock screen renders its
/// countdown natively from the segment window (`Text(timerInterval:)`), so
/// there are never per-tick updates — exactly the web's contract.
///
/// KEEP-IN-SYNC note: the widget extension (a SEPARATE process, no Core
/// dependency) never compiles this manager or `GuidedActivityContent` — it
/// renders the wire `ContentState` in `GuidedProtocolActivityAttributes`
/// verbatim. What is genuinely shared is that Attributes type: one source
/// file (`Sources/Shared/GuidedProtocolActivityAttributes.swift`), compiled
/// into BOTH targets from this project, so the ActivityKit
/// `Attributes`/`ContentState` shape cannot drift — keep it that way: the
/// wire type must stay in `Sources/Shared`, never duplicated, and the widget
/// must never start importing Core logic.
///
/// Live Activities do not run in the simulator's gallery — device-only to
/// verify; every failure here is swallowed so the protocol itself is never
/// affected.
@MainActor
public final class GuidedProtocolActivityManager {
    private var activity: Activity<GuidedProtocolActivityAttributes>?
    private var run: ForceProtocolRun?
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
        self.run = run
        peakKilograms = nil
        // The initial push comes from the run's LIVE anchor (stageStartedAt
        // is set by the view's onAppear before this is called), never from
        // the frozen schedule — a Skip Stage before the first natural
        // boundary must not resurface a past segment.
        guard let snapshot = currentAnchorSnapshot() else {
            self.content = nil
            self.run = nil
            return
        }
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
            self.run = nil
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
        run = nil
        peakKilograms = nil
        Task {
            await activity.end(
                nil,
                dismissalPolicy: immediate ? .immediate : .default
            )
        }
    }

    /// #674 review F7: reconcile any activity that survived a force-quit or
    /// jetsam. Every teardown path runs in-process (`onDisappear`, Finish,
    /// Cancel, the interrupted branch), so a killed app leaves the card
    /// stranded on the lock screen; the system's lifetime cap eventually
    /// retires it, but the launch/foreground sweep is the only way to clear
    /// it NOW. Called when no run is in progress.
    public func reconcileOrphans() {
        guard !isActive, !Activity<GuidedProtocolActivityAttributes>.activities.isEmpty else { return }
        let activities = Activity<GuidedProtocolActivityAttributes>.activities
        Task {
            for activity in activities {
                await activity.end(
                    nil,
                    dismissalPolicy: .immediate
                )
            }
        }
    }

    private func currentAnchorSnapshot() -> GuidedProtocolActivityContent.Snapshot? {
        guard let content, let run else { return nil }
        let anchor = GuidedProtocolActivityContent.RunAnchor(
            run: run,
            at: Date()
        )
        return content.snapshot(runAnchor: anchor, peakKilograms: peakKilograms)
    }

    private func pushSnapshot() {
        guard let activity, let snapshot = currentAnchorSnapshot() else { return }
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
