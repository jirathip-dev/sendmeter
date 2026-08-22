import XCTest
@testable import SendmeterCore
import SendLogWatchCore

/// The controller glue over the shared `HandsFreeForce` machine: actions are
/// claimed exactly once per rep, stops re-arm per their reason, and the
/// transport disconnect reconciles the machine without ever re-arming.
@MainActor
final class HandsFreeForceControllerTests: XCTestCase {
    @MainActor
    private final class Hooks {
        var armStreamCalls = 0
        var disarmStreamCalls = 0
        var beginRecordingCalls = 0
        var stopAndSaveCalls = 0
        var autoReArmCalls = 0

        func attach(to controller: HandsFreeForceController) {
            controller.onArmStream = { [weak self] in self?.armStreamCalls += 1 }
            controller.onDisarmStream = { [weak self] in self?.disarmStreamCalls += 1 }
            controller.onBeginRecording = { [weak self] in self?.beginRecordingCalls += 1 }
            controller.onStopAndSave = { [weak self] in self?.stopAndSaveCalls += 1 }
            controller.onAutoReArm = { [weak self] in self?.autoReArmCalls += 1 }
        }
    }

    private let config = HandsFreeForceConfig(
        startKg: 2,
        stopKg: 1,
        startStableMs: 600,
        stopGraceMs: 1_500
    )

    private func pullTimeline(armedAt: Double, releasedAt: Double) -> [(ms: Double, kg: Double)] {
        // 2s of load above the start threshold (600ms stable), then 2s below
        // the stop threshold (1.5s grace).
        var samples: [(ms: Double, kg: Double)] = []
        for step in 0..<20 { samples.append((armedAt + Double(step) * 100, 12)) }
        for step in 0..<25 { samples.append((releasedAt + Double(step) * 100, 0.5)) }
        return samples
    }

    func testArmStartsStreamAndLoadTriggersSingleBegin() {
        let controller = HandsFreeForceController(config: config)
        let hooks = Hooks()
        hooks.attach(to: controller)

        controller.arm()
        XCTAssertTrue(controller.isArmed)
        XCTAssertEqual(hooks.armStreamCalls, 1)

        // Below the threshold: nothing.
        controller.feed(atMs: 0, kg: 0.5)
        controller.feed(atMs: 500, kg: 0.5)
        XCTAssertEqual(hooks.beginRecordingCalls, 0)

        // Continuous load ≥ startKg for startStableMs → exactly one begin.
        // (Only the load side of the timeline — a release would stop again.)
        for step in 0..<20 {
            controller.feed(atMs: 1_000 + Double(step) * 100, kg: 12)
        }
        XCTAssertEqual(hooks.beginRecordingCalls, 1)
        XCTAssertTrue(controller.isMeasuring)
        XCTAssertFalse(controller.isArmed)
    }

    func testReleaseTriggersExactlyOneStopAndSaveThenRearmsArmed() {
        let controller = HandsFreeForceController(config: config)
        let hooks = Hooks()
        hooks.attach(to: controller)

        controller.arm()
        for sample in pullTimeline(armedAt: 0, releasedAt: 8_000) {
            controller.feed(atMs: sample.ms, kg: sample.kg)
        }
        XCTAssertEqual(hooks.beginRecordingCalls, 1)
        XCTAssertEqual(hooks.stopAndSaveCalls, 1)

        // Subsequent samples must not emit the stop again (the `.stopping`
        // phase is the claim).
        controller.feed(atMs: 10_500, kg: 0.4)
        controller.feed(atMs: 11_000, kg: 0.4)
        XCTAssertEqual(hooks.stopAndSaveCalls, 1)

        // The release was proven, so the re-arm needs no fresh slack.
        controller.rearmAfterSave()
        XCTAssertTrue(controller.isArmed)
        XCTAssertEqual(hooks.autoReArmCalls, 1)

        // And the next pull begins a new rep.
        for sample in pullTimeline(armedAt: 12_000, releasedAt: 20_000) {
            controller.feed(atMs: sample.ms, kg: sample.kg)
        }
        XCTAssertEqual(hooks.beginRecordingCalls, 2)
        XCTAssertEqual(hooks.stopAndSaveCalls, 2)
    }

    func testTrimEndIsOnRecordingClock() {
        let controller = HandsFreeForceController(config: config)
        let hooks = Hooks()
        hooks.attach(to: controller)

        controller.arm()
        // Load applied at 5_000; the recording begins 600ms later (startStable),
        // so the release point at 15_000 is 15_000 - 5_600 = 9_400ms on the
        // RECORDING clock — the trim the saved rep must end at (#503).
        for sample in pullTimeline(armedAt: 5_000, releasedAt: 15_000) {
            controller.feed(atMs: sample.ms, kg: sample.kg)
        }
        let trim = controller.consumeTrimEndMilliseconds()
        XCTAssertEqual(trim ?? -1, 9_400, accuracy: 100)

        // A manual tap stop has no proven release point.
        let manual = HandsFreeForceController(config: config)
        let manualHooks = Hooks()
        manualHooks.attach(to: manual)
        manual.arm()
        for step in 0..<20 {
            manual.feed(atMs: 0 + Double(step) * 100, kg: 12)
        }
        XCTAssertEqual(manualHooks.beginRecordingCalls, 1)
        manual.stopManually()
        XCTAssertEqual(manualHooks.stopAndSaveCalls, 1)
        XCTAssertNil(manual.consumeTrimEndMilliseconds())
    }

    func testStaticLoadTerminationSetsReasonAndTrimToFlatWindowStart() {
        let controller = HandsFreeForceController(config: config)
        let hooks = Hooks()
        hooks.attach(to: controller)

        controller.arm()
        // Load applied at 0; the recording begins at 600 (startStableMs).
        // A 4 kg spike at 1_000 breaks the 0.25 kg flat band, resetting the
        // flat window to that sample; the subsequent flat 4 kg load then runs
        // for 30 s (flatlineWindowMs), so the machine terminates as
        // `.staticLoad` with the trim at the flat-window start (1_000 on the
        // feed clock).
        controller.feed(atMs: 0, kg: 3)
        for step in 1...9 {
            controller.feed(atMs: Double(step) * 100, kg: 3)
        }
        for step in 10...310 {
            controller.feed(atMs: Double(step) * 100, kg: 4)
        }
        XCTAssertEqual(hooks.beginRecordingCalls, 1)
        XCTAssertEqual(hooks.stopAndSaveCalls, 1)

        // The trim is the flat-window start on the RECORDING clock:
        // 1_000 (flat-window start) - 600 (recording began) = 400 ms.
        XCTAssertEqual(controller.consumeTrimEndMilliseconds() ?? -1, 400, accuracy: 100)

        // A `.staticLoad` re-arms through waiting-for-slack, never straight to
        // armed — it has no proof of slack (the sustained load may still hang).
        controller.rearmAfterSave()
        XCTAssertEqual(controller.state, HandsFreeForceState.waitingForSlack)
        XCTAssertEqual(hooks.autoReArmCalls, 1)
    }

    func testManualStopRequiresSlackBeforeNextPull() {
        let controller = HandsFreeForceController(config: config)
        let hooks = Hooks()
        hooks.attach(to: controller)

        controller.arm()
        // Load applied; the recording begins; the user taps Stop & Save
        // while still hanging.
        for step in 0..<20 {
            controller.feed(atMs: Double(step) * 100, kg: 12)
        }
        XCTAssertEqual(hooks.beginRecordingCalls, 1)
        controller.stopManually()
        XCTAssertEqual(hooks.stopAndSaveCalls, 1)
        controller.rearmAfterSave()
        // A manual tap re-arms into waiting-for-slack, never straight to
        // armed: the same continuous load must not become a phantom rep.
        XCTAssertEqual(controller.state, HandsFreeForceState.waitingForSlack)

        // Still hanging: the same continuous load must not become a phantom
        // second rep (#467).
        for step in 0..<30 {
            controller.feed(atMs: 2_500 + Double(step) * 100, kg: 12)
        }
        XCTAssertEqual(hooks.beginRecordingCalls, 1)

        // Slack observed → armed → the next pull is recognized.
        for step in 0..<5 {
            controller.feed(atMs: 5_600 + Double(step) * 100, kg: 0.4)
        }
        XCTAssertTrue(controller.isArmed)
        for step in 0..<20 {
            controller.feed(atMs: 6_100 + Double(step) * 100, kg: 12)
        }
        XCTAssertEqual(hooks.beginRecordingCalls, 2)
    }

    func testCallerOwnedStopPolicyNeverSavesThroughController() {
        let controller = HandsFreeForceController(config: config)
        let hooks = Hooks()
        hooks.attach(to: controller)
        controller.stopPolicy = .callerOwned

        controller.arm()
        // The machine still gates the START of a guided work stage...
        for sample in pullTimeline(armedAt: 0, releasedAt: 8_000) {
            controller.feed(atMs: sample.ms, kg: sample.kg)
        }
        XCTAssertEqual(hooks.beginRecordingCalls, 1)
        // ...but the stage timer owns every stop/save — a mid-stage release
        // must never trigger the free-pull save (double-count protection).
        XCTAssertEqual(hooks.stopAndSaveCalls, 0)

        // The next work stage re-arms directly.
        controller.arm()
        XCTAssertTrue(controller.isArmed)
        XCTAssertEqual(hooks.armStreamCalls, 2)
    }

    func testCancelArmStopsStreamWithoutRecording() {
        let controller = HandsFreeForceController(config: config)
        let hooks = Hooks()
        hooks.attach(to: controller)

        controller.arm()
        controller.feed(atMs: 0, kg: 0.5)
        XCTAssertTrue(controller.isArmed)
        controller.cancelArm()
        XCTAssertFalse(controller.isArmed)
        XCTAssertEqual(hooks.disarmStreamCalls, 1)
        XCTAssertEqual(hooks.beginRecordingCalls, 0)
    }

    func testDisconnectReconcilesToIdleAndNeverRearms() {
        let controller = HandsFreeForceController(config: config)
        let hooks = Hooks()
        hooks.attach(to: controller)

        controller.arm()
        for sample in pullTimeline(armedAt: 0, releasedAt: 8_000) {
            controller.feed(atMs: sample.ms, kg: sample.kg)
        }
        XCTAssertEqual(hooks.stopAndSaveCalls, 1)

        controller.handleDisconnected()
        XCTAssertFalse(controller.isArmed)
        XCTAssertEqual(hooks.disarmStreamCalls, 1)
        XCTAssertEqual(hooks.autoReArmCalls, 0)

        // No pending reason survives the disconnect, so a stale save
        // completion cannot re-arm a dead stream.
        controller.rearmAfterSave()
        XCTAssertEqual(hooks.autoReArmCalls, 0)
        XCTAssertFalse(controller.isArmed)
    }

    func testArmRefusesWhileRecording() {
        let controller = HandsFreeForceController(config: config)
        let hooks = Hooks()
        hooks.attach(to: controller)

        controller.arm()
        // Load applied; the recording begins; the machine is `.recording`.
        for step in 0..<20 {
            controller.feed(atMs: Double(step) * 100, kg: 12)
        }
        XCTAssertTrue(controller.isMeasuring)
        controller.arm()
        XCTAssertTrue(controller.isMeasuring)
        XCTAssertEqual(hooks.armStreamCalls, 1)
    }

    func testDisarmIsNoOpWhenIdle() {
        let controller = HandsFreeForceController(config: config)
        let hooks = Hooks()
        hooks.attach(to: controller)
        controller.disarm()
        XCTAssertEqual(hooks.disarmStreamCalls, 0)
    }
}
