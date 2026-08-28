import XCTest
import SendLogWatchCore

final class ForceRuntimePolicyTests: XCTestCase {
    // MARK: State-machine transitions

    func testIdleToMeasuringRequiresRuntimeThenFinishedReleases() {
        // idle → measuring: measured work starts, runtime must isolate.
        XCTAssertEqual(
            ForceRuntimePolicy.runtimeRequirement(for: .idle, mode: .freeHold),
            .none
        )
        XCTAssertEqual(
            ForceRuntimePolicy.runtimeRequirement(for: .measuring, mode: .freeHold),
            .isolate(reason: .freeHoldPull)
        )
        // measuring → finished: terminal state releases.
        XCTAssertEqual(
            ForceRuntimePolicy.runtimeRequirement(for: .finished, mode: .freeHold),
            .none
        )
    }

    func testMeasuringToSalvagingToIdleReleasesRuntime() {
        XCTAssertEqual(
            ForceRuntimePolicy.runtimeRequirement(for: .measuring, mode: .handsFree),
            .isolate(reason: .handsFreePull)
        )
        XCTAssertEqual(
            ForceRuntimePolicy.runtimeRequirement(for: .salvaging, mode: .handsFree),
            .none
        )
        XCTAssertEqual(
            ForceRuntimePolicy.runtimeRequirement(for: .idle, mode: .handsFree),
            .none
        )
    }

    func testNoDuplicateAcquireAcrossRepeatedMeasuringUpdates() {
        // A refresh that re-reads the same measured state stays isolated; the
        // "should not re-cue" property is pinned separately by
        // `testStartHapticDoesNotReplayForSameState`.
        for _ in 0..<3 {
            XCTAssertEqual(
                ForceRuntimePolicy.runtimeRequirement(for: .measuring, mode: .freeHold),
                .isolate(reason: .freeHoldPull)
            )
        }
    }

    func testReleaseOnEveryTerminalState() {
        for state in [ForceActivityState.idle, .guidedRest, .salvaging, .finished] {
            for mode in ForceActivityMode.allCases {
                XCTAssertEqual(
                    ForceRuntimePolicy.runtimeRequirement(for: state, mode: mode),
                    .none,
                    "\(state) / \(mode) must not hold runtime"
                )
            }
        }
    }

    func testGuidedRestVsGuidedWorkRuntime() {
        XCTAssertEqual(
            ForceRuntimePolicy.runtimeRequirement(for: .guidedWork, mode: .guided),
            .isolate(reason: .guidedWork)
        )
        XCTAssertEqual(
            ForceRuntimePolicy.runtimeRequirement(for: .guidedRest, mode: .guided),
            .none
        )
    }

    func testGuidedMeasuringRouteFallbackIsIsolated() {
        // Defensive: if the coordinator ever reports `.measuring` while in
        // guided mode, real measured work is still active.
        XCTAssertEqual(
            ForceRuntimePolicy.runtimeRequirement(for: .measuring, mode: .guided),
            .isolate(reason: .guidedWork)
        )
    }

    // MARK: Reduced-luminance spec

    func testReducedLuminanceSpecForFreeHold() {
        let spec = ForceRuntimePolicy.reducedLuminanceSpec(for: .measuring, mode: .freeHold)
        XCTAssertTrue(spec.showsCurrentForce)
        XCTAssertTrue(spec.showsPeakForce)
        XCTAssertTrue(spec.showsPhaseCountdown)
        XCTAssertTrue(spec.showsSide)
        XCTAssertEqual(spec.stateWord, "Hold")
    }

    func testReducedLuminanceSpecForHandsFree() {
        let spec = ForceRuntimePolicy.reducedLuminanceSpec(for: .measuring, mode: .handsFree)
        XCTAssertTrue(spec.showsCurrentForce)
        XCTAssertTrue(spec.showsPeakForce)
        XCTAssertTrue(spec.showsPhaseCountdown)
        XCTAssertTrue(spec.showsSide)
        XCTAssertEqual(spec.stateWord, "Pull")
    }

    func testReducedLuminanceSpecForGuidedWork() {
        let spec = ForceRuntimePolicy.reducedLuminanceSpec(for: .guidedWork, mode: .guided)
        XCTAssertTrue(spec.showsCurrentForce)
        XCTAssertTrue(spec.showsPeakForce)
        XCTAssertTrue(spec.showsPhaseCountdown)
        XCTAssertTrue(spec.showsSide)
        XCTAssertEqual(spec.stateWord, "Work")
    }

    func testReducedLuminanceSpecForGuidedRest() {
        let spec = ForceRuntimePolicy.reducedLuminanceSpec(for: .guidedRest, mode: .guided)
        XCTAssertFalse(spec.showsCurrentForce)
        XCTAssertFalse(spec.showsPeakForce)
        XCTAssertTrue(spec.showsPhaseCountdown)
        XCTAssertTrue(spec.showsSide)
        XCTAssertEqual(spec.stateWord, "Rest")
    }

    func testReducedLuminanceSpecForIdle() {
        let spec = ForceRuntimePolicy.reducedLuminanceSpec(for: .idle, mode: .freeHold)
        XCTAssertFalse(spec.showsCurrentForce)
        XCTAssertFalse(spec.showsPeakForce)
        XCTAssertFalse(spec.showsPhaseCountdown)
        XCTAssertFalse(spec.showsSide)
        XCTAssertEqual(spec.stateWord, "Ready")
    }

    func testReducedLuminanceSpecForTerminalStates() {
        let salvaging = ForceRuntimePolicy.reducedLuminanceSpec(for: .salvaging, mode: .freeHold)
        XCTAssertEqual(salvaging.stateWord, "Saving")
        XCTAssertFalse(salvaging.showsCurrentForce)
        let finished = ForceRuntimePolicy.reducedLuminanceSpec(for: .finished, mode: .guided)
        XCTAssertEqual(finished.stateWord, "Done")
        XCTAssertFalse(finished.showsCurrentForce)
    }

    // MARK: Haptic mapping

    func testStartHapticFiresOnEnteringMeasuredWork() {
        XCTAssertTrue(
            ForceRuntimePolicy.shouldStartHaptic(from: .idle, to: .measuring)
        )
        XCTAssertTrue(
            ForceRuntimePolicy.shouldStartHaptic(from: .idle, to: .guidedWork)
        )
        XCTAssertTrue(
            ForceRuntimePolicy.shouldStartHaptic(from: .guidedRest, to: .guidedWork)
        )
    }

    func testStartHapticDoesNotReplayForSameState() {
        // A repeated update that re-reads the same measured state must not
        // re-cue the start haptic (the "no duplicate acquire" intent at the
        // haptic layer).
        XCTAssertFalse(
            ForceRuntimePolicy.shouldStartHaptic(from: .measuring, to: .measuring)
        )
        XCTAssertFalse(
            ForceRuntimePolicy.shouldStartHaptic(from: .guidedWork, to: .guidedWork)
        )
    }

    func testStartHapticDoesNotFireOnReentryFromTerminal() {
        XCTAssertFalse(
            ForceRuntimePolicy.shouldStartHaptic(from: .finished, to: .idle)
        )
        XCTAssertFalse(
            ForceRuntimePolicy.shouldStartHaptic(from: .measuring, to: .guidedRest)
        )
    }

    func testAcknowledgeHapticForBoundaryEvents() {
        for event in [ForceHapticEvent.start, .stop, .save, .salvage, .failure, .finish, .holdPeak] {
            XCTAssertTrue(
                ForceRuntimePolicy.shouldAcknowledgeHaptic(for: event),
                "\(event) should be acknowledged"
            )
        }
    }

    // MARK: #791 W3 — one subtle hold-peak milestone cue per rep.

    func testHoldPeakCuesExactlyOnceWhenForceSettlesBelowTheRepPeak() {
        var tracker = ForcePeakHapticTracker()
        XCTAssertFalse(tracker.shouldCue(forceKg: 80), "rising into the pull")
        XCTAssertFalse(tracker.shouldCue(forceKg: 90))
        XCTAssertFalse(tracker.shouldCue(forceKg: 92), "the rep peak so far")
        XCTAssertTrue(tracker.shouldCue(forceKg: 89.5), "2.5 kg below the peak — the milestone")
        XCTAssertFalse(tracker.shouldCue(forceKg: 85), "once cued, the rest of the rep stays silent")
        XCTAssertFalse(tracker.shouldCue(forceKg: 60))
        XCTAssertFalse(tracker.shouldCue(forceKg: 92.1), "a late re-hang above the peak is not a cue")
    }

    func testHoldPeakTrackerResetsBetweenReps() {
        var tracker = ForcePeakHapticTracker()
        XCTAssertFalse(tracker.shouldCue(forceKg: 90))
        XCTAssertTrue(tracker.shouldCue(forceKg: 87.5))
        tracker.reset()
        XCTAssertFalse(tracker.shouldCue(forceKg: 50), "a fresh rep must be able to cue its own peak")
        XCTAssertFalse(tracker.shouldCue(forceKg: 55))
        XCTAssertTrue(tracker.shouldCue(forceKg: 52.8))
    }

    func testHoldPeakTrackerNeverCuesWithoutAMeasuredPeak() {
        var tracker = ForcePeakHapticTracker()
        XCTAssertFalse(tracker.shouldCue(forceKg: 0), "no measurement, no cue")
        XCTAssertFalse(tracker.shouldCue(forceKg: .nan), "non-finite samples are ignored")
    }
}
