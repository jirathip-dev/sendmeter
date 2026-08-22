import ActivityKit
import Foundation
import SendmeterCore

/// Lock-screen Live Activity for the guided force protocol (#628) — the
/// native equivalent of the web's `src/lib/liveActivity.ts` + the
/// `sendlog-live-activity` plugin's Tindeq activity.
///
/// The pure content model + countdown mapping live in SendmeterCore
/// (`GuidedActivityContent` + `GuidedActivityMirror`); this manager is the
/// thin ActivityKit adapter: it starts the activity with the run's schedule,
/// pushes the snapshot ONLY on state transitions (stage changes, hold-end
/// peak, Skip Stage, run complete) and ends it when the protocol ends. The
/// lock screen renders its countdown natively from the segment window
/// (`Text(timerInterval:)`), so there are never per-tick updates — exactly
/// the web's contract.
///
/// #674 review N1: this manager NEVER stores a `ForceProtocolRun`. A run is a
/// struct, so a copy cached here would freeze the card on the stage captured
/// at `start()` — the exact defect that shipped in the previous round. The
/// authoritative run lives in the parent-owned
/// `GuidedForceProtocolSession`; every push takes the LIVE run value
/// (`refresh(run:at:)` / `updatePeak(_:run:at:)`), and the mirror in Core
/// derives the snapshot from it at call time. Nothing derived from the run
/// may be cached across a transition.
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
    private var mirror: GuidedActivityMirror?

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
        var mirror = GuidedActivityMirror(content: content)
        self.mirror = mirror
        // The initial push comes from the run's LIVE anchor (stageStartedAt
        // is set by the view's onAppear before this is called), never from
        // the frozen schedule — a Skip Stage before the first natural
        // boundary must not resurface a past segment.
        let snapshot = mirror.snapshot(run: run, at: Date())
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
            self.mirror = nil
        }
    }

    /// Rebuild the snapshot at the current instant from the LIVE run — called
    /// on every stage transition, never on a tick.
    public func refresh(run: ForceProtocolRun, at date: Date = Date(), paused: Bool = false) {
        guard activity != nil else { return }
        pushSnapshot(run: run, at: date, paused: paused)
    }

    /// Bank the hold's final peak on the card (called when a work stage
    /// ends) and push from the LIVE run.
    public func updatePeak(_ kilograms: Double?, run: ForceProtocolRun, at date: Date = Date()) {
        mirror?.bankPeak(kilograms)
        pushSnapshot(run: run, at: date)
    }

    /// Take the activity down. `immediate` for protocol end/cancel; a
    /// lingering dismissal would show a stale card for the system's default
    /// window.
    public func end(immediate: Bool = true) {
        guard let activity else { return }
        self.activity = nil
        mirror = nil
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

    private func pushSnapshot(run: ForceProtocolRun, at date: Date, paused: Bool = false) {
        guard let activity, let mirror else { return }
        let snapshot = mirror.snapshot(run: run, at: date, isPaused: paused ? true : nil)
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
            peakKilograms: snapshot.peakKilograms,
            targetKilograms: snapshot.targetKilograms,
            isPaused: snapshot.isPaused
        )
    }
}
