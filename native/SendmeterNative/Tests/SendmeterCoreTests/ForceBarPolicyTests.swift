@testable import SendmeterCore
import XCTest

/// #1028 D + F: the sticky Force bar's decisions, per locked amendment F.
final class ForceBarPolicyTests: XCTestCase {
    private func bar(
        _ device: ForceBarDevice,
        _ mode: ForceBarMode = .guided,
        armed: String? = "Max Hangs 10 s",
        handsFreeArmed: Bool = false,
        handsFreeMeasuring: Bool = false,
        held: Bool = false,
        session: Bool = false,
        recordings: Bool = true
    ) -> ForceBarState {
        ForceBarPolicy.state(
            ForceBarInput(
                device: device,
                mode: mode,
                armedProtocolName: armed,
                handsFreeArmed: handsFreeArmed,
                handsFreeMeasuring: handsFreeMeasuring,
                hasHeldPull: held,
                guidedSessionActive: session,
                hasRecordings: recordings
            )
        )
    }

    // F2 — Guided: Connect → Start (the armed protocol) → Stop & save.
    func testGuidedSequence() {
        XCTAssertEqual(bar(.disconnected, recordings: false).action, .connect)
        XCTAssertEqual(bar(.disconnected).action, .reconnect)
        XCTAssertEqual(bar(.connected).action, .startGuided)
        XCTAssertEqual(bar(.connected).actionTitle, "Start")
        XCTAssertEqual(bar(.measuring).action, .stopAndSave)
        XCTAssertEqual(bar(.measuring).actionTitle, "Stop & save")
    }

    // F2 — Hands-free: Connect → Arm → (pull) → saves on release.
    func testHandsFreeSequence() {
        XCTAssertEqual(bar(.disconnected, .handsFree, recordings: false).action, .connect)
        XCTAssertEqual(bar(.connected, .handsFree).action, .armHandsFree)
        XCTAssertEqual(bar(.connected, .handsFree).actionTitle, "Arm")
        let armed = bar(.connected, .handsFree, handsFreeArmed: true)
        XCTAssertEqual(armed.action, .disarmHandsFree)
        XCTAssertEqual(armed.status, "Armed · pull to start")
        XCTAssertEqual(bar(.measuring, .handsFree, handsFreeMeasuring: true).action, .stopAndSave)
    }

    // D2: nothing armed in Guided — the action opens the protocol list.
    func testGuidedNothingArmedChoosesAProtocol() {
        let state = bar(.connected, armed: nil)
        XCTAssertEqual(state.action, .chooseProtocol)
        XCTAssertEqual(state.subject, ForceBarPolicy.nothingArmedSubject)
        XCTAssertTrue(state.subjectOpensProtocolList)
    }

    // D2: the armed protocol name is the tap target for the list.
    func testArmedNameOpensTheList() {
        let state = bar(.connected)
        XCTAssertEqual(state.subject, "Max Hangs 10 s")
        XCTAssertTrue(state.subjectOpensProtocolList)
        XCTAssertFalse(bar(.connected, .handsFree).subjectOpensProtocolList)
    }

    // D3: one word for the disconnected state. P11 (owner-accepted
    // exception): the interrupted state says "Connection lost" instead.
    func testOneWordForDisconnected() {
        XCTAssertEqual(bar(.disconnected).status, "Disconnected")
        XCTAssertEqual(bar(.disconnected, .handsFree).status, "Disconnected")
        XCTAssertEqual(bar(.interrupted).action, .reconnect)
        for device in [ForceBarDevice.disconnected, .interrupted, .bluetoothOff, .connecting, .connected, .measuring] {
            for mode in ForceBarMode.allCases {
                let status = bar(device, mode).status
                XCTAssertFalse(["Not connected", "Offline", "Interrupted"].contains(status), "\(device) \(mode): \(status)")
            }
        }
    }

    // P11: interrupted mid-pull, the bar says the link was lost — in both
    // modes, with or without recordings. Plain idle never says it.
    func testInterruptedSaysConnectionLost() {
        for mode in ForceBarMode.allCases {
            for recordings in [true, false] {
                let state = bar(.interrupted, mode, recordings: recordings)
                XCTAssertEqual(state.status, "Connection lost", "\(mode) recordings=\(recordings)")
                XCTAssertEqual(state.action, .reconnect)
                XCTAssertEqual(state.actionTitle, "Reconnect")
                XCTAssertNotEqual(bar(.disconnected, mode, recordings: recordings).status, "Connection lost")
            }
        }
        // A held pull still wins: the bar offers Save first.
        XCTAssertEqual(bar(.interrupted, held: true).status, "Unsaved pull")
    }

    // P9: compact heights collapse the large title while a pull records.
    func testCompactHeightCollapsesTheTitleOnlyWhileRecording() {
        // iPhone SE (3rd gen): 667 pt.
        XCTAssertTrue(ForceTitlePolicy.collapsesLargeTitle(screenHeight: 667, recording: true))
        XCTAssertFalse(ForceTitlePolicy.collapsesLargeTitle(screenHeight: 667, recording: false))
        // iPhone 17 Pro: 874 pt keeps the large title.
        XCTAssertFalse(ForceTitlePolicy.collapsesLargeTitle(screenHeight: 874, recording: true))
        // Before the first layout pass the height is unknown: no collapse.
        XCTAssertFalse(ForceTitlePolicy.collapsesLargeTitle(screenHeight: 0, recording: true))
    }

    // The mode switch locks while anything owns the device.
    func testModeSwitchLocks() {
        XCTAssertFalse(bar(.connected).modeLocked)
        XCTAssertTrue(bar(.measuring).modeLocked)
        XCTAssertTrue(bar(.connected, .handsFree, handsFreeArmed: true).modeLocked)
        XCTAssertTrue(bar(.connected, session: true).modeLocked)
    }

    // D4: a held pull is settled from the bar before anything new starts.
    func testHeldPullIsReachableFromTheBar() {
        XCTAssertEqual(bar(.connected, held: true).action, .saveHeldPull)
        XCTAssertEqual(bar(.interrupted, held: true).action, .saveHeldPull)
        XCTAssertEqual(bar(.connected, .handsFree, held: true).action, .saveHeldPull)
        // …but a live pull always wins (Stop & save).
        XCTAssertEqual(bar(.measuring, held: true).action, .stopAndSave)
    }

    func testRunningSessionResumes() {
        XCTAssertEqual(bar(.connected, session: true).action, .resumeGuided)
    }

    func testBluetoothOffAndConnecting() {
        XCTAssertEqual(bar(.bluetoothOff).action, .openBluetoothSettings)
        XCTAssertEqual(bar(.connecting).action, .cancelConnecting)
        XCTAssertFalse(bar(.connecting).actionIsPrimary)
    }

    // F3: the context card never claims a live/armed state without a link.
    func testContextCardWaitsForProgressorWhenDisconnected() {
        for device in [ForceBarDevice.disconnected, .interrupted, .bluetoothOff, .connecting] {
            for mode in ForceBarMode.allCases {
                let readiness = ForceContextReadiness(device: device, mode: mode, handsFreeArmed: true)
                XCTAssertEqual(readiness.claim, .waitingForProgressor)
                XCTAssertEqual(readiness.title, "Waiting for Progressor")
                XCTAssertFalse(readiness.showsLiveReadout)
                XCTAssertFalse(readiness.title.contains("Armed"))
                XCTAssertFalse(readiness.detail.contains("Armed now"))
            }
        }
    }

    func testContextCardClaimsFollowTheMode() {
        let guided = ForceContextReadiness(device: .connected, mode: .guided, handsFreeArmed: false)
        XCTAssertEqual(guided.claim, .guidedReady)
        XCTAssertEqual(guided.modeChip, "Guided")
        XCTAssertTrue(guided.showsLiveReadout)
        let ready = ForceContextReadiness(device: .connected, mode: .handsFree, handsFreeArmed: false)
        XCTAssertFalse(ready.detail.contains("Armed now"), "not armed yet — must not claim it")
        let armed = ForceContextReadiness(device: .connected, mode: .handsFree, handsFreeArmed: true)
        XCTAssertEqual(armed.detail, "Armed now · no confirmation step")
        XCTAssertEqual(armed.modeChip, "Hands-free")
    }

    // F4: labelled hold time.
    func testHoldLabel() {
        XCTAssertEqual(ForceReadoutFormat.hold(milliseconds: 30_300), "Hold 30.3 s")
        XCTAssertEqual(ForceReadoutFormat.hold(milliseconds: -5), "Hold 0.0 s")
    }

    // F4: a light scale — at most four nice ticks, none on the top edge.
    func testTraceScaleTicks() {
        XCTAssertEqual(ForceTraceScale.ticks(maxValue: 40), [10, 20, 30])
        XCTAssertEqual(ForceTraceScale.ticks(maxValue: 36), [10, 20, 30])
        XCTAssertEqual(ForceTraceScale.ticks(maxValue: 9), [2.5, 5, 7.5])
        XCTAssertEqual(ForceTraceScale.ticks(maxValue: 0), [])
        XCTAssertEqual(ForceTraceScale.ticks(maxValue: .nan), [])
        for maxValue in stride(from: 1.0, through: 250, by: 3.7) {
            let ticks = ForceTraceScale.ticks(maxValue: maxValue)
            XCTAssertLessThanOrEqual(ticks.count, ForceTraceScale.maxTicks)
            XCTAssertFalse(ticks.isEmpty, "\(maxValue)")
            XCTAssertTrue(ticks.allSatisfy { $0 < maxValue })
        }
        XCTAssertEqual(ForceTraceScale.label(30, isTop: true), "30 kg")
        XCTAssertEqual(ForceTraceScale.label(7.5, isTop: false), "7.5")
    }
}
