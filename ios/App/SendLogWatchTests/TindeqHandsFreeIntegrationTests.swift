import Foundation
import SendLogWatchCore
import XCTest
@testable import SendLogWatch_Watch_App

@MainActor
final class TindeqHandsFreeIntegrationTests: XCTestCase {
    func testHandsFreeRepThenManualRepShareSessionFeedDepletionAndFinishOnce() async throws {
        let recordings = RecordingQueueSpy()
        let sessions = SessionQueueSpy()
        var commands: [Tindeq.Cmd] = []
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            armTimeoutSeconds: 600,
            commandWriter: { commands.append($0) }
        )
        manager.liveTag = "Half crimp"
        manager.liveSide = "left"
        manager.tagCurves["Half crimp"] = TindeqTagInfo(name: "Half crimp", cf: 10, wPrime: 100)

        manager.armHandsFree()
        XCTAssertEqual(manager.handsFreeState, .armed(aboveSinceMs: nil))
        XCTAssertEqual(commands, [.startWeight])

        // 50 kg is deliberately pre-start: the old idle guard discards all of
        // these samples; the fixed armed path observes them without buffering.
        feed(manager, [(50, 0), (0, 500_000), (2.5, 1_000_000), (2.5, 1_600_000)])
        XCTAssertEqual(manager.status, .measuring)
        XCTAssertEqual(
            manager.handsFreeState,
            .recording(
                belowSinceMs: nil,
                flatWatch: HandsFreeForceFlatWatch(sinceMs: 0, minKg: 2.5, maxKg: 2.5)
            )
        )

        // Labels are snapshotted at Start, not read by the later async save.
        manager.liveTag = "Changed after start"
        manager.liveSide = "right"
        feed(manager, [(30, 1_700_000), (0.5, 1_800_000), (0, 3_299_000)])
        let beforeGraceCount = await recordings.count()
        XCTAssertEqual(beforeGraceCount, 0, "release grace has not elapsed")
        feed(manager, [(0, 3_300_000)])

        try await waitUntil { manager.sessionCount == 1 && !manager.saving }
        let firstRows = await recordings.snapshot()
        let first = try XCTUnwrap(firstRows.first?.row)
        XCTAssertEqual(firstRows.count, 1)
        XCTAssertEqual(first.tag, "Half crimp")
        XCTAssertEqual(first.side, "left")
        XCTAssertEqual(first.groupId, manager.sessionId)
        XCTAssertEqual(try XCTUnwrap(first.peakKg), 30, accuracy: 0.01)
        XCTAssertEqual(first.durationMs, 200, "the 1.5 s low-force grace tail is not recorded")
        XCTAssertFalse(first.samples.contains { $0[1] == 50 }, "armed samples must never leak into the rep")
        XCTAssertTrue(manager.predictedRPE.fromCurve)
        XCTAssertGreaterThan(manager.predictedRPE.load ?? 0, 0)
        XCTAssertEqual(manager.handsFreeState, .armed(aboveSinceMs: nil))
        XCTAssertEqual(commands, [.startWeight, .stop, .startWeight])

        // Turn hands-free off and prove the pre-existing manual path still
        // records normally, on the same per-connect group.
        manager.cancelHandsFree()
        manager.liveTag = "Half crimp"
        manager.liveSide = "right"
        manager.start()
        feed(manager, [(4, 4_000_000), (20, 4_250_000), (0, 4_500_000)])
        manager.stopAndSave(reason: .userTapped)
        manager.stopAndSave(reason: .userTapped) // near-simultaneous duplicate loses the sync claim

        try await waitUntil { manager.sessionCount == 2 && !manager.saving }
        let allRows = await recordings.snapshot().map(\.row)
        XCTAssertEqual(allRows.count, 2, "the stop race must enqueue one manual rep, not two")
        XCTAssertEqual(allRows[1].side, "right")
        XCTAssertEqual(allRows[1].groupId, first.groupId)
        XCTAssertFalse(manager.handsFreeRequested)
        XCTAssertEqual(manager.handsFreeState, .idle)
        XCTAssertEqual(manager.status, .connected)

        manager.logSessionNow()
        try await waitUntil { await sessions.count() == 1 }
        let loggedSessions = await sessions.snapshot()
        let logged = try XCTUnwrap(loggedSessions.first)
        XCTAssertEqual(logged.groupId, first.groupId)
        XCTAssertEqual(logged.note, "2 recordings")
        XCTAssertFalse(manager.handsFreeRequested, "Finish disarms hands-free")
    }

    func testManualDisconnectSalvageStillAutoLogsAfterHandsFreeIsTurnedOff() async throws {
        let recordings = RecordingQueueSpy()
        let sessions = SessionQueueSpy()
        var commands: [Tindeq.Cmd] = []
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            armTimeoutSeconds: 600,
            commandWriter: { commands.append($0) }
        )
        manager.liveTag = "Open hand"
        manager.liveSide = "left"

        // First bank a hands-free rep so this regression test fails against
        // the old idle-sample blocker by value (one row), not by missing API.
        manager.armHandsFree()
        feed(manager, [(3, 0), (3, 600_000), (15, 700_000), (0, 800_000), (0, 2_300_000)])
        try await waitUntil { manager.sessionCount == 1 && !manager.saving }
        manager.cancelHandsFree()

        // Hands-free is now off. A normal manual hold dropped by BLE must keep
        // the existing #151 salvage note/path and #280 finish behavior.
        manager.start()
        feed(manager, [(5, 3_000_000), (18, 3_100_000), (12, 3_200_000)])
        manager.handleTransportDisconnect(
            error: NSError(domain: "BLE", code: -1),
            wasIntentionalOverride: false
        )

        try await waitUntil { await sessions.count() == 1 }
        let rows = await recordings.snapshot().map(\.row)
        XCTAssertEqual(rows.count, 2)
        let salvaged = try XCTUnwrap(rows.last)
        XCTAssertEqual(salvaged.note, "Recovered after connection loss")
        if let first = rows.first, rows.count > 1 {
            XCTAssertEqual(salvaged.groupId, first.groupId)
        }
        let loggedSessions = await sessions.snapshot()
        let logged = try XCTUnwrap(loggedSessions.first)
        XCTAssertEqual(logged.note, "2 recordings")
        XCTAssertEqual(manager.status, .idle)
        XCTAssertFalse(manager.handsFreeRequested)
        XCTAssertEqual(manager.handsFreeState, .idle)
    }

    /// #590 review F1, layer by layer against the REAL manager: with
    /// hands-free armed, a pull can start a rep while the finish
    /// confirmation covers the gauge. `ForceFinishPolicy` (Core) is the
    /// seam `ForceGaugeView` routes both protection layers through — the
    /// status flip to `.measuring` is what dismisses the card, and a
    /// same-instant confirm tap must refuse to execute. Then the guarded
    /// (refused) confirm provably costs nothing: the rep completes and
    /// saves normally.
    func testFinishPolicyRefusesMidPullAndGuardedRepStillSaves() async throws {
        let recordings = RecordingQueueSpy()
        let sessions = SessionQueueSpy()
        var commands: [Tindeq.Cmd] = []
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            armTimeoutSeconds: 600,
            commandWriter: { commands.append($0) }
        )
        manager.liveTag = "Half crimp"
        manager.liveSide = "left"

        manager.armHandsFree()
        // Armed but idle: the confirmation may open, and finishing may run.
        XCTAssertTrue(ForceFinishPolicy.mayExecuteFinish(isMeasuring: manager.status == .measuring))
        XCTAssertFalse(ForceFinishPolicy.shouldDismissConfirmation(isMeasuring: manager.status == .measuring))

        // The pull lands mid-confirmation.
        feed(manager, [(3, 0), (15, 600_000)])
        XCTAssertEqual(manager.status, .measuring)
        XCTAssertTrue(
            ForceFinishPolicy.shouldDismissConfirmation(isMeasuring: manager.status == .measuring),
            "an open confirmation must dismiss the moment recording starts"
        )
        XCTAssertFalse(
            ForceFinishPolicy.mayExecuteFinish(isMeasuring: manager.status == .measuring),
            "a confirm tap racing the pull must execute nothing"
        )

        // The guarded (refused) confirm is a no-op: the rep completes and
        // saves exactly as if the flag had never been tapped.
        feed(manager, [(14, 700_000), (0, 800_000), (0, 2_300_000)])
        try await waitUntil { manager.sessionCount == 1 && !manager.saving }
        let savedRows = await recordings.snapshot()
        XCTAssertEqual(savedRows.count, 1, "the rep the guard protected must save")
    }

    /// The hazard itself, demonstrated: the UNGUARDED finish pairing
    /// (`logSessionNow()` + `disconnect()`) mid-pull discards the recording
    /// rep — `disconnect()` drops the claim and marks the disconnect
    /// intentional, which also suppresses the BLE-loss salvage. This is the
    /// canary for the guard's reason to exist: if the manager ever stops
    /// discarding here, the policy can be revisited.
    func testUnguardedFinishMidPullDiscardsTheRecordingRep() async throws {
        let recordings = RecordingQueueSpy()
        let sessions = SessionQueueSpy()
        var commands: [Tindeq.Cmd] = []
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            armTimeoutSeconds: 600,
            commandWriter: { commands.append($0) }
        )
        manager.liveTag = "Half crimp"
        manager.liveSide = "left"

        manager.armHandsFree()
        feed(manager, [(3, 0), (15, 600_000)])
        XCTAssertEqual(manager.status, .measuring)

        manager.logSessionNow()
        manager.disconnect()

        try await waitUntil { manager.status == .idle && !manager.saving }
        // A discarded claim cannot save late; give any stray async work a
        // beat before asserting the loss is real.
        try await Task.sleep(nanoseconds: 300_000_000)
        let rows = await recordings.snapshot()
        XCTAssertEqual(rows.count, 0, "mid-pull disconnect discards the recording rep — the interleaving the policy exists to prevent")
        let logged = await sessions.count()
        XCTAssertEqual(logged, 0, "nothing was banked, so nothing may be logged")
    }

    /// SL-585 (#591): with NOTHING selected, arming is the free-hold primary
    /// — the old manager-level empty-tag refusals (armHandsFree's guard and
    /// beginArmedRecording's cancel-and-toast) are gone. An untagged pull
    /// must arm, record, and save as a `""`-tagged rep (the recordings
    /// schema's own default — Free hold's existing representation, no new
    /// tag scheme), losing nothing.
    func testUntaggedArmRecordsFreeHoldRepAndLosesNothing() async throws {
        let recordings = RecordingQueueSpy()
        let sessions = SessionQueueSpy()
        var commands: [Tindeq.Cmd] = []
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            armTimeoutSeconds: 600,
            commandWriter: { commands.append($0) }
        )
        manager.liveTag = ""
        manager.liveSide = ""

        manager.armHandsFree()
        XCTAssertTrue(manager.handsFreeRequested, "an empty tag must not refuse arming any more (#591)")
        XCTAssertEqual(manager.handsFreeState, .armed(aboveSinceMs: nil))

        feed(manager, [(3, 0), (3, 600_000), (15, 700_000), (0, 800_000), (0, 2_300_000)])
        try await waitUntil { manager.sessionCount == 1 && !manager.saving }

        let rows = await recordings.snapshot().map(\.row)
        XCTAssertEqual(rows.count, 1, "the untagged pull must record exactly one rep")
        let rep = try XCTUnwrap(rows.first)
        XCTAssertEqual(rep.tag, "", "a free hold records with the schema's own empty-tag default")
        XCTAssertEqual(rep.groupId, manager.sessionId, "the untagged rep joins the per-connect session like any other")
        XCTAssertEqual(
            manager.handsFreeState, .armed(aboveSinceMs: nil),
            "hands-free re-arms after the untagged save, same as tagged"
        )
    }

    func testArmedStreamAutoDisarmsAtTenMinuteIdleBound() {
        var commands: [Tindeq.Cmd] = []
        let manager = TindeqManager(
            recordingQueue: RecordingQueueSpy(),
            sessionQueue: SessionQueueSpy(),
            armTimeoutSeconds: 600,
            commandWriter: { commands.append($0) }
        )
        manager.liveTag = "Half crimp"
        manager.armHandsFree()

        feed(manager, [(0, 1_000), (0, 600_001_000)])

        XCTAssertFalse(manager.handsFreeRequested)
        XCTAssertEqual(manager.handsFreeState, .idle)
        XCTAssertEqual(commands, [.startWeight, .stop])
    }

    func testAutoReleaseTapRaceSavesOnceAndLoadedManualStopNeedsSlack() async throws {
        let recordings = RecordingQueueSpy()
        var commands: [Tindeq.Cmd] = []
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: SessionQueueSpy(),
            armTimeoutSeconds: 600,
            commandWriter: { commands.append($0) }
        )
        manager.liveTag = "Half crimp"
        manager.liveSide = "left"

        manager.armHandsFree()
        feed(manager, [(3, 0), (3, 600_000), (35, 700_000), (0, 800_000), (0, 2_300_000)])

        // Exercise the production auto-release call site racing user taps.
        // Its synchronous claim must make both duplicates no-ops.
        manager.stopAndSave(reason: .userTapped)
        manager.stopAndSave(reason: .userTapped)
        try await waitUntil { manager.sessionCount == 1 && !manager.saving }
        let rowsAfterRace = await recordings.count()
        XCTAssertEqual(rowsAfterRace, 1)
        XCTAssertEqual(manager.handsFreeState, .armed(aboveSinceMs: nil))

        // Auto-release already proved 1.5 s of slack. Even if the next
        // delivered sample is a fresh pull after the save/restart dark window,
        // the complete 600 ms stability window must start rep 2.
        feed(manager, [(3, 2_500_000), (3, 3_100_000), (35, 3_200_000)])
        XCTAssertEqual(manager.status, .measuring)

        // The climber taps while still hanging. Persistence can resolve before
        // they unload, but that same 35 kg must not become a phantom next rep.
        manager.stopAndSave(reason: .userTapped)
        try await waitUntil { manager.sessionCount == 2 && !manager.saving }
        XCTAssertEqual(manager.handsFreeState, .waitingForSlack)
        feed(manager, [(35, 3_300_000), (35, 4_000_000)])
        XCTAssertEqual(manager.status, .connected)
        XCTAssertEqual(manager.handsFreeState, .waitingForSlack)
        let rowsWhileStillLoaded = await recordings.count()
        XCTAssertEqual(rowsWhileStillLoaded, 2)
        // #681: the tap save keeps the weight stream live (the machine must
        // observe the release inside the save window), so a tap save emits no
        // .stop and the re-arm emits no .startWeight — the stream never gaped.
        XCTAssertEqual(commands, [.startWeight, .stop, .startWeight])
    }

    /// #681 — the deterministic repro of the #607 report. A tap save while
    /// hanging re-arms through `waitingForSlack`, which must OBSERVE the
    /// release before the next pull can arm. If the save's async window is
    /// where the user releases (the real-BLE case: the transport was stopped,
    /// so the release edge was DROPPED), the re-arm would see only a resumed
    /// loaded stream and strand the machine — the second pull never records.
    /// The fix keeps the weight stream live through the tap save so the
    /// machine observes the release inside the save window, and the re-arm
    /// preserves the armed machine instead of stamping waitingForSlack over it.
    func testTapSaveWhileHangingReleaseDuringSaveWindowRearmsForNextPull() async throws {
        let recordings = RecordingQueueSpy()
        var commands: [Tindeq.Cmd] = []
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: SessionQueueSpy(),
            armTimeoutSeconds: 600,
            commandWriter: { commands.append($0) }
        )
        manager.liveTag = "Half crimp"
        manager.liveSide = "left"

        manager.armHandsFree()
        feed(manager, [(3, 0), (3, 600_000), (25, 700_000)])
        XCTAssertEqual(manager.status, .measuring)

        // The user taps "Stop & Save" while still hanging. With the stream kept
        // live, the release that follows is observed during the save window.
        manager.stopAndSave(reason: .userTapped)
        feed(manager, [(0.5, 800_000)])
        XCTAssertEqual(
            manager.handsFreeState, .armed(aboveSinceMs: nil),
            "the release inside the live save window must arm the machine"
        )
        try await waitUntil { manager.sessionCount == 1 && !manager.saving }
        XCTAssertEqual(
            manager.handsFreeState, .armed(aboveSinceMs: nil),
            "the re-arm must preserve the armed machine observed during the save"
        )

        // The next pull starts and records with no user interaction.
        feed(manager, [(3, 900_000), (3, 1_500_000)])
        XCTAssertEqual(manager.status, .measuring)
        feed(manager, [(25, 1_600_000), (0.5, 1_700_000), (0.5, 3_200_000)])
        try await waitUntil { manager.sessionCount == 2 && !manager.saving }
        // The .released save re-arms straight to armed; wait for that so the
        // command list below is settled (the re-arm runs after `saving` flips).
        try await waitUntil { manager.handsFreeState == .armed(aboveSinceMs: nil) }
        let rows = await recordings.snapshot().map(\.row)
        XCTAssertEqual(rows.count, 2, "the second pull must record after a tap save with slack inside the save window")
        // .startWeight (arm) + .stop (rep 2's release) + .startWeight (rep 2's
        // re-arm). Rep 1 was a TAP save: its stream stayed live (no .stop) and
        // its re-arm preserved the armed machine (no .startWeight).
        XCTAssertEqual(commands, [.startWeight, .stop, .startWeight])
    }

    /// #681 — the phantom-rep guard preserved: a tap save while still hanging
    /// with NO release in the save window must keep waiting for slack; the
    /// same continuous load must never become a second rep.
    func testTapSaveWhileHangingNoReleaseStaysWaitingForSlack() async throws {
        let recordings = RecordingQueueSpy()
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: SessionQueueSpy(),
            armTimeoutSeconds: 600,
            commandWriter: { _ in }
        )
        manager.liveTag = "Half crimp"
        manager.liveSide = "left"

        manager.armHandsFree()
        feed(manager, [(3, 0), (3, 600_000), (25, 700_000)])
        XCTAssertEqual(manager.status, .measuring)

        manager.stopAndSave(reason: .userTapped)
        // The user keeps hanging through the whole save — no slack sample.
        feed(manager, [(25, 800_000), (25, 1_500_000), (25, 2_000_000)])
        try await waitUntil { manager.sessionCount == 1 && !manager.saving }
        XCTAssertEqual(
            manager.handsFreeState, .waitingForSlack,
            "no release observed = still waiting for slack (phantom guard)"
        )
        let rows = await recordings.snapshot()
        XCTAssertEqual(rows.count, 1, "the same continuous load must not become a second rep")
    }

    func testThirtyMinuteCapSavesOneUntrimmedRepAndWaitsForSlack() async throws {
        // #681 review F1: the save is held open with a blocking queue so a
        // post-cap sample can be fed INSIDE the save window — the exact
        // scenario the stale pre-rep idle base used to mis-fire on.
        let recordings = BlockingRecordingQueueSpy()
        var commands: [Tindeq.Cmd] = []
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: SessionQueueSpy(),
            armTimeoutSeconds: 600,
            commandWriter: { commands.append($0) }
        )
        manager.liveTag = "Half crimp"
        manager.liveSide = "left"

        manager.armHandsFree()
        feed(manager, [(3, 0), (3, 600_000), (25, 700_000)])
        XCTAssertEqual(manager.status, .measuring)

        // Still fully loaded when the rep hits the 30-minute cap: only the
        // UI timer's cap check can stop it, and that stop must not get
        // release semantics (#503) — no proven slack, no trimmed tail.
        feed(manager, [(25, 1_800_600_000)])
        try await waitUntil { manager.saving }
        // #681 review F1 regression: the cap save keeps the stream LIVE, so
        // this post-cap sample lands INSIDE the save window at a device
        // timestamp ~30 min past arming (3x the 10-minute arm timeout). The
        // idle budget was re-based at save-window entry, so it must NOT
        // cancel — the stale pre-rep base would have computed 30 min of
        // "idle" and disarmed the gauge mid-save (dead under #683).
        feed(manager, [(25, 1_801_000_000)])
        XCTAssertTrue(
            manager.handsFreeRequested,
            "a save-window sample at a device timestamp past the arm timeout must NOT cancel hands-free"
        )
        XCTAssertEqual(manager.handsFreeState, .waitingForSlack)
        XCTAssertEqual(commands, [.startWeight], "the save-window sample must not emit a .stop")
        await recordings.releaseAll()
        try await waitUntil { manager.sessionCount == 1 && !manager.saving }
        let rows = await recordings.snapshot().map(\.row)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].durationMs, 1_800_000, "a cap stop has no release point to trim at")
        XCTAssertEqual(manager.handsFreeState, .waitingForSlack)

        // The same continuous 25 kg spans well past the 600 ms stable window.
        // If the cap ever re-armed with release semantics, this would start a
        // phantom rep #467-style; it must stay an armed-side no-op.
        feed(manager, [(25, 1_801_000_000), (25, 1_801_800_000)])
        XCTAssertEqual(manager.status, .connected)
        XCTAssertEqual(manager.handsFreeState, .waitingForSlack)
        let rowsWhileStillLoaded = await recordings.count()
        XCTAssertEqual(rowsWhileStillLoaded, 1)

        // After real slack the machine still arms and starts the next rep.
        feed(manager, [(0.5, 1_802_000_000), (3, 1_802_200_000), (3, 1_802_900_000)])
        XCTAssertEqual(manager.status, .measuring)
        // #681: the cap save keeps the weight stream live so the machine can
        // observe the release inside the save window — no .stop/.startWeight.
        XCTAssertEqual(commands, [.startWeight])
    }

    func testWallClockTimeoutDisarmsAQuietPostSaveRearm() async throws {
        let recordings = RecordingQueueSpy()
        var commands: [Tindeq.Cmd] = []
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: SessionQueueSpy(),
            // Must exceed the fixed 600 ms stable-pull window so the device-
            // timestamp cutoff does not win before this rep starts.
            armTimeoutSeconds: 0.8,
            commandWriter: { commands.append($0) }
        )
        manager.liveTag = "Open hand"

        manager.armHandsFree()
        feed(manager, [(3, 0), (3, 600_000), (25, 700_000)])
        manager.stopAndSave(reason: .userTapped)
        try await waitUntil { manager.sessionCount == 1 && !manager.saving }
        XCTAssertEqual(manager.handsFreeState, .waitingForSlack)

        // No more samples: only the wall-clock Timer can disarm this stream.
        try await waitUntil { !manager.handsFreeRequested }
        XCTAssertEqual(manager.handsFreeState, .idle)
        XCTAssertEqual(manager.savedMsg, "Hands-free disarmed after 10 min idle")
        // #681: the tap save keeps the stream live (no .stop); only the
        // timeout's own disarm writes .stop.
        XCTAssertEqual(commands, [.startWeight, .stop])
    }

    func testMissingSalvageClaimReportsLossAndLogsPriorSession() async throws {
        _ = RecordingLossNotice.consume()
        let sessions = SessionQueueSpy()
        let manager = TindeqManager(
            recordingQueue: RecordingQueueSpy(),
            sessionQueue: sessions,
            commandWriter: { _ in }
        )
        manager.liveTag = "Open hand"
        manager.armHandsFree()
        let groupId = manager.ensureSession()
        manager.sessionCount = 1

        manager.salvageInterruptedRecording(
            StoppedRecording(
                durationMs: 40_000,
                peakKg: 35,
                avgKg: 30,
                samples: [(t: 0, kg: 35), (t: 40_000, kg: 25)]
            ),
            wasHandsFree: false
        )

        try await waitUntil { await sessions.count() == 1 }
        XCTAssertTrue(RecordingLossNotice.consume())
        XCTAssertEqual(manager.errorMsg, "Interrupted force rep was not saved — recovery state was missing.")
        let loggedSessions = await sessions.snapshot()
        let logged = try XCTUnwrap(loggedSessions.first)
        XCTAssertEqual(logged.groupId, groupId)
        XCTAssertEqual(logged.note, "1 recording")
    }

    func testLostDisconnectSalvageDoesNotTellUserToPullAgain() async throws {
        _ = RecordingLossNotice.consume()
        let recordings = RecordingQueueSpy(outcome: .lost)
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: SessionQueueSpy(),
            commandWriter: { _ in }
        )
        manager.liveTag = "Open hand"
        manager.start()
        feed(manager, [(5, 0), (25, 100_000), (20, 200_000)])

        manager.handleTransportDisconnect(
            error: NSError(domain: "BLE", code: -1),
            wasIntentionalOverride: false
        )

        try await waitUntil { !manager.saving }
        let recordingCount = await recordings.count()
        XCTAssertEqual(recordingCount, 1)
        XCTAssertEqual(manager.savedMsg, "Recovered rep was not saved")
        XCTAssertFalse(manager.savedMsg?.localizedCaseInsensitiveContains("pull") ?? true)
        XCTAssertEqual(manager.errorMsg, "Rep not saved — couldn't write to the watch.")
        XCTAssertTrue(RecordingLossNotice.consume())
    }

    /// #682 follow-up (reviewer blocking finding): the disconnect-salvage
    /// funnel is ALSO a persist boundary for a hands-free rep. A trivial rep
    /// (peak < `minPeakKg` or duration < `minDurationMs`) interrupted by a BLE
    /// drop must be discarded — it never enters the recording queue and is
    /// never reported as queued. Manual interrupted reps are unchanged.
    func testHandsFreeTrivialRepDisconnectSalvageIsDiscarded() async throws {
        let recordings = RecordingQueueSpy()
        let sessions = SessionQueueSpy()
        var commands: [Tindeq.Cmd] = []
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            armTimeoutSeconds: 600,
            commandWriter: { commands.append($0) }
        )
        manager.liveTag = "Open hand"

        manager.armHandsFree()
        // 2.9 kg crosses startKg (2) at t=0; at t=600 the 600 ms stable window
        // elapses and the rep begins. The 2.9 kg samples (t=0 and t=100 on the
        // recording clock) keep the machine recording but the peak (2.9 kg)
        // stays below `minPeakKg` (3) and the duration (100 ms) is below
        // `minDurationMs` (1 500), so Guard 1 discards it at the salvage
        // persist boundary.
        feed(manager, [(2.9, 0), (2.9, 600_000), (2.9, 700_000)])
        XCTAssertEqual(manager.status, .measuring)

        manager.handleTransportDisconnect(
            error: NSError(domain: "BLE", code: -1),
            wasIntentionalOverride: false
        )

        try await waitUntil { !manager.saving }
        let recordingCount = await recordings.count()
        XCTAssertEqual(recordingCount, 0, "a discarded hands-free rep must never enter the queue")
        let sessionCount = await sessions.count()
        XCTAssertEqual(sessionCount, 0, "a discarded rep must never be reported as a queued session")
        XCTAssertFalse(manager.handsFreeRequested, "transport loss must clear the hands-free arm")
        XCTAssertEqual(manager.handsFreeState, .idle)
        XCTAssertEqual(manager.status, .idle)
        XCTAssertFalse(manager.savedMsg?.localizedCaseInsensitiveContains("Recovered") ?? false)
        // No stop command was written: the transport loss is the terminator and
        // the stream is already idle, so the next connect re-arms cleanly.
        XCTAssertEqual(commands, [.startWeight])
    }

    /// #682 follow-up: the complement to the discard gate — a qualifying
    /// hands-free rep interrupted by a BLE drop (peak ≥ `minPeakKg` and
    /// duration ≥ `minDurationMs`) is still salvaged and persisted through the
    /// same funnel, so Guard 1 does not over-discard real reps.
    func testHandsFreeQualifyingRepDisconnectSalvageIsPersisted() async throws {
        let recordings = RecordingQueueSpy()
        let sessions = SessionQueueSpy()
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            armTimeoutSeconds: 600,
            commandWriter: { _ in }
        )
        manager.liveTag = "Open hand"

        manager.armHandsFree()
        // 3.1 kg crosses startKg (2) at t=0; the rep begins at t=600. The
        // second sample lands at t=1 600 on the recording clock (2.2 s device
        // time), so peak (3.1 kg) ≥ `minPeakKg` (3) and duration (1 600 ms) ≥
        // `minDurationMs` (1 500) — Guard 1 must PERSIST it.
        feed(manager, [(3.1, 0), (3.1, 600_000), (3.1, 2_200_000)])
        XCTAssertEqual(manager.status, .measuring)

        manager.handleTransportDisconnect(
            error: NSError(domain: "BLE", code: -1),
            wasIntentionalOverride: false
        )

        try await waitUntil { manager.sessionCount == 1 && !manager.saving }
        let recordingCount = await recordings.count()
        XCTAssertEqual(recordingCount, 1)
        let snapshot = await recordings.snapshot()
        let row = try XCTUnwrap(snapshot.first?.row)
        XCTAssertEqual(row.tag, "Open hand")
        XCTAssertEqual(try XCTUnwrap(row.peakKg), 3.1, accuracy: 0.01)
        XCTAssertEqual(row.durationMs, 1_600)
        XCTAssertTrue(row.note.localizedCaseInsensitiveContains("Recovered"))
    }

    func testGuidedMovementDisconnectKeepsSessionOpenForLaterCadenceSets() async throws {
        let recordings = RecordingQueueSpy()
        let sessions = SessionQueueSpy()
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            commandWriter: { _ in }
        )
        let protocolValue = WatchForceProtocol.movementStarter
        let runId = UUID()

        XCTAssertTrue(
            manager.startMeasuredMovementSet(
                protocolValue: protocolValue,
                runId: runId,
                set: 1,
                tag: "Half crimp",
                side: "left"
            )
        )
        feed(manager, [(5, 0), (20, 5_000_000), (18, 15_000_000)])
        manager.handleTransportDisconnect(
            error: NSError(domain: "BLE", code: -1),
            wasIntentionalOverride: false
        )

        try await waitUntil { manager.sessionCount == 1 && !manager.saving }
        let groupId = try XCTUnwrap(manager.sessionId)
        let sessionsBeforeFinish = await sessions.count()
        XCTAssertEqual(sessionsBeforeFinish, 0, "movement salvage must not log early")

        XCTAssertTrue(
            manager.saveCadenceOnlyMovementSet(
                protocolValue: protocolValue,
                runId: runId,
                set: 2,
                tag: "Half crimp",
                side: "left",
                actualDurationMs: 40_000
            )
        )
        try await waitUntil { manager.sessionCount == 2 && !manager.saving }
        let rows = await recordings.snapshot().map(\.row)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.groupId == groupId })
        XCTAssertNil(rows[1].peakKg, "cadence-only continuation must have no force claim")

        manager.logSessionNow()
        try await waitUntil { await sessions.count() == 1 }
        let loggedSessions = await sessions.snapshot()
        let logged = try XCTUnwrap(loggedSessions.first)
        XCTAssertEqual(logged.groupId, groupId)
        XCTAssertEqual(logged.note, "2 recordings")
    }

    func testGuidedStaticDisconnectSalvageRemainsTerminalAndLogsOnce() async throws {
        let recordings = RecordingQueueSpy()
        let sessions = SessionQueueSpy()
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            commandWriter: { _ in }
        )
        let protocolValue = WatchForceProtocol(
            id: "static-regression",
            name: "Static regression",
            holdS: 10,
            reps: 1,
            sets: 1,
            restRepsS: 0,
            restSetsS: 0
        )

        XCTAssertTrue(
            manager.startMeasuredStaticHold(
                protocolValue: protocolValue,
                runId: UUID(),
                set: 1,
                rep: 1,
                tag: "Half crimp",
                side: "left"
            )
        )
        feed(manager, [(5, 0), (25, 5_000_000), (20, 8_000_000)])
        manager.handleTransportDisconnect(
            error: NSError(domain: "BLE", code: -1),
            wasIntentionalOverride: false
        )

        try await waitUntil { await sessions.count() == 1 && !manager.saving }
        let recordingCount = await recordings.count()
        XCTAssertEqual(recordingCount, 1)
        XCTAssertNil(manager.sessionId, "terminal static salvage logs and clears the session")
        let loggedSessions = await sessions.snapshot()
        let logged = try XCTUnwrap(loggedSessions.first)
        XCTAssertEqual(logged.note, "1 recording")
    }

    func testGuidedFinishAndNextStartInOneDelayedTickShareSessionDespitePendingSave() async throws {
        let account = UUID()
        let recordings = BlockingRecordingQueueSpy()
        let sessions = SessionQueueSpy()
        var commands: [Tindeq.Cmd] = []
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            commandWriter: { commands.append($0) },
            userIdProvider: { account }
        )
        let protocolValue = WatchForceProtocol(
            id: "zero-rest-boundary",
            name: "Zero rest boundary",
            holdS: 1,
            reps: 1,
            sets: 2,
            restRepsS: 0,
            restSetsS: 0,
            mode: .reverseAction,
            cadenceOutS: 2,
            cadenceReturnS: 2,
            prepareS: 5
        )
        let runner = GuidedForceRunner(userIdProvider: { account })

        XCTAssertTrue(
            runner.start(
                protocolValue: protocolValue,
                tag: "Half crimp",
                side: "left",
                manager: manager
            )
        )
        let startedAt = try XCTUnwrap(runner.runState?.startedAt)

        // A delayed foreground tick crosses set 1's finish and set 2's start
        // in the same ordered event list. Keep set 1's queue await pending so
        // the regression proves transport readiness is not row durability.
        runner.advance(to: startedAt.addingTimeInterval(5.1))
        feed(manager, [(12, 0), (25, 100_000)])
        runner.advance(to: startedAt.addingTimeInterval(9.1))
        try await waitUntil { await recordings.count() == 1 && manager.saving }
        XCTAssertNotEqual(runner.phase, .failed)
        XCTAssertTrue(runner.isMeasured, "set 2 must own the transport immediately")
        XCTAssertEqual(manager.status, .measuring)
        XCTAssertEqual(commands, [.startWeight, .stop, .startWeight])

        // Finish set 2 through the same late tick, then release both immutable
        // row writes. The manager's finish gate must log one session only after
        // both rows are durable, retaining the original group id.
        feed(manager, [(10, 0), (20, 100_000)])
        runner.advance(to: startedAt.addingTimeInterval(protocolValue.durationS))
        try await waitUntil { await recordings.count() == 2 && manager.saving }
        await recordings.releaseAll()

        try await waitUntil {
            await sessions.count() == 1 && manager.sessionCount == 0 && !manager.saving
        }
        let rows = await recordings.snapshot().map(\.row)
        XCTAssertEqual(rows.count, 2, "finish/start boundary must not drop or duplicate a row")
        XCTAssertEqual(Set(rows.compactMap(\.groupId)).count, 1)
        XCTAssertEqual(Set(rows.compactMap(\.setNo)), Set([1, 2]))
        let loggedSessionCount = await sessions.count()
        XCTAssertEqual(loggedSessionCount, 1)
        XCTAssertEqual(runner.phase, .completed)
    }

    func testLegacyOverCapMovementPresetIsNormalizedBeforeGuidedSave() async throws {
        let account = UUID()
        let json = Data("""
        {
          "id": "legacy-long-movement",
          "name": "Legacy long movement",
          "hold_s": 40,
          "reps": 50,
          "sets": 1,
          "rest_reps_s": 0,
          "rest_sets_s": 0,
          "target_kg": null,
          "target_pct": null,
          "protocol_mode": "reverse_action",
          "cadence_out_s": 30,
          "cadence_return_s": 30,
          "prepare_s": 5
        }
        """.utf8)
        let protocolValue = try JSONDecoder().decode(WatchForceProtocol.self, from: json)
        XCTAssertEqual(protocolValue.reps, 29)
        XCTAssertLessThan(protocolValue.movementSetDurationS, 1_800)

        let recordings = RecordingQueueSpy()
        let sessions = SessionQueueSpy()
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            commandWriter: { _ in },
            userIdProvider: { account }
        )
        let runner = GuidedForceRunner(userIdProvider: { account })
        XCTAssertTrue(
            runner.start(
                protocolValue: protocolValue,
                tag: "Half crimp",
                side: "left",
                manager: manager
            )
        )
        let startedAt = try XCTUnwrap(runner.runState?.startedAt)
        runner.advance(to: startedAt.addingTimeInterval(5.1))
        feed(manager, [(12, 0), (25, 100_000)])
        runner.advance(to: startedAt.addingTimeInterval(protocolValue.durationS))

        try await waitUntil {
            await sessions.count() == 1 && manager.sessionCount == 0 && !manager.saving
        }
        let rows = await recordings.snapshot().map(\.row)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].plannedDurationMs, 1_740_000)
        XCTAssertEqual(rows[0].setNo, 1)
        XCTAssertEqual(runner.phase, .completed)
    }

#if DEBUG && targetEnvironment(simulator)
    func testSimulatorFakeTransportDropsStaleQueuedConnectCallbackAfterReconnect() async throws {
        let transport = FakeTindeqTransport(script: shortFakeScript())
        var connectCount = 0
        transport.onConnect = { connectCount += 1 }

        transport.connect()
        transport.disconnect()
        transport.connect()

        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(connectCount, 1)
        XCTAssertTrue(transport.connected)
        transport.disconnect()
    }

    func testSimulatorFakeTransportStopsWithoutDisconnectAfterSynchronousNotificationStop() async throws {
        let script = FakeTindeqScript(
            scenario: .midRepDisconnect,
            waveform: FakeTindeqWaveform(
                configuration: FakeTindeqWaveformConfiguration(
                    baselineKg: 0.2,
                    peakKg: 12,
                    rampMs: 1,
                    holdMs: 2,
                    releaseMs: 100,
                    restMs: 100,
                    sampleIntervalMs: 20,
                    noiseKg: 0,
                    seed: 567
                )
            )
        )
        let transport = FakeTindeqTransport(script: script)
        var notificationCount = 0
        var disconnectCount = 0
        transport.onNotification = { [weak transport] _ in
            notificationCount += 1
            if notificationCount == 2 {
                transport?.write(.stop)
            }
        }
        transport.onDisconnect = { _ in disconnectCount += 1 }

        transport.connect()
        transport.write(.startWeight)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(notificationCount, 2)
        XCTAssertEqual(disconnectCount, 0)
        XCTAssertTrue(transport.connected)
        transport.disconnect()
    }

    func testSimulatorFakeTransportConnectsManualRecordAndExplicitDisconnectUsesManagerPath() async throws {
        let recordings = RecordingQueueSpy()
        let transport = FakeTindeqTransport(script: shortFakeScript())
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: SessionQueueSpy(),
            fakeTransport: transport,
            userIdProvider: { UUID() }
        )
        manager.liveTag = "Half crimp"
        manager.liveSide = "left"

        manager.connect()
        try await waitUntil { manager.status == .connected }
        XCTAssertTrue(transport.connected)

        manager.start()
        try await waitUntil { manager.status == .measuring && manager.elapsedMs > 0 }
        manager.stopAndSave(reason: .userTapped)
        try await waitUntil { await recordings.count() == 1 && !manager.saving }

        let manualRows = await recordings.snapshot()
        let row = try XCTUnwrap(manualRows.first?.row)
        XCTAssertEqual(row.tag, "Half crimp")
        XCTAssertEqual(row.side, "left")
        XCTAssertGreaterThan(row.samples.count, 1)

        // The explicit path is intentionally silent to the salvage handler.
        manager.disconnect()
        XCTAssertEqual(manager.status, .idle)
        XCTAssertFalse(transport.connected)
    }

    func testSimulatorFakeTransportHandsFreePullTriggersReleaseAndRearms() async throws {
        let recordings = RecordingQueueSpy()
        let transport = FakeTindeqTransport(script: shortFakeScript())
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: SessionQueueSpy(),
            armTimeoutSeconds: 30,
            fakeTransport: transport
        )
        manager.liveTag = "Open hand"
        manager.liveSide = "right"

        manager.connect()
        try await waitUntil { manager.status == .connected }
        manager.armHandsFree()
        try await waitUntil(timeout: .seconds(8)) {
            await recordings.count() == 1 && !manager.saving
        }

        XCTAssertEqual(manager.handsFreeState, .armed(aboveSinceMs: nil))
        XCTAssertEqual(manager.sessionCount, 1)
        let handsFreeRows = await recordings.snapshot()
        XCTAssertEqual(handsFreeRows.first?.row.side, "right")
        manager.cancelHandsFree()
        manager.disconnect()
    }

    func testSimulatorFakeTransportTwoBackToBackPullsRecordTwoReps() async throws {
        let recordings = RecordingQueueSpy()
        let transport = FakeTindeqTransport(script: shortFakeScript())
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: SessionQueueSpy(),
            armTimeoutSeconds: 30,
            fakeTransport: transport
        )
        manager.liveTag = "Open hand"
        manager.liveSide = "right"

        manager.connect()
        try await waitUntil { manager.status == .connected }
        manager.armHandsFree()

        // Pull 1 auto-saves on release and re-arms.
        try await waitUntil(timeout: .seconds(8)) {
            await recordings.count() == 1 && !manager.saving
        }
        XCTAssertEqual(manager.handsFreeState, .armed(aboveSinceMs: nil))

        // Pull 2 (the waveform restarts on the re-arm's .startWeight) must
        // auto-start and save with no user interaction — the #607 scenario.
        try await waitUntil(timeout: .seconds(8)) {
            await recordings.count() == 2 && !manager.saving
        }
        let rows = await recordings.snapshot().map(\.row)
        XCTAssertEqual(rows.count, 2, "a second back-to-back pull must record a second rep")
        XCTAssertEqual(Set(rows.compactMap(\.groupId)).count, 1, "both reps join one session")
        manager.cancelHandsFree()
        manager.disconnect()
    }

    func testSimulatorFakeTransportGuidedStaticHoldUsesMeasuredSavePath() async throws {
        let recordings = RecordingQueueSpy()
        let transport = FakeTindeqTransport(script: shortFakeScript())
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: SessionQueueSpy(),
            fakeTransport: transport,
            userIdProvider: { UUID() }
        )
        let protocolValue = WatchForceProtocol(
            id: "fake-static",
            name: "Fake static",
            holdS: 2,
            reps: 1,
            sets: 1,
            restRepsS: 0,
            restSetsS: 0
        )
        manager.liveTag = "Half crimp"
        manager.liveSide = "left"
        manager.connect()
        try await waitUntil { manager.status == .connected }

        XCTAssertTrue(
            manager.startMeasuredStaticHold(
                protocolValue: protocolValue,
                runId: UUID(),
                set: 1,
                rep: 1,
                tag: "Half crimp",
                side: "left"
            )
        )
        try await waitUntil { manager.status == .measuring && manager.elapsedMs > 0 }
        XCTAssertTrue(manager.finishMeasuredStaticHold())
        try await waitUntil { await recordings.count() == 1 && !manager.saving }

        let guidedRows = await recordings.snapshot()
        let row = try XCTUnwrap(guidedRows.first?.row)
        XCTAssertNotNil(row.protocolRunId)
        XCTAssertEqual(row.side, "left")
        XCTAssertGreaterThan(row.samples.count, 1)
        manager.disconnect()
    }

    func testSimulatorFakeTransportMidRepDisconnectSalvagesAndAutoLogs() async throws {
        let recordings = RecordingQueueSpy()
        let sessions = SessionQueueSpy()
        let transport = FakeTindeqTransport(script: shortFakeScript(.midRepDisconnect))
        let manager = TindeqManager(
            recordingQueue: recordings,
            sessionQueue: sessions,
            fakeTransport: transport,
            userIdProvider: { UUID() }
        )
        manager.liveTag = "Half crimp"
        manager.liveSide = "left"
        manager.connect()
        try await waitUntil { manager.status == .connected }

        manager.start()
        try await waitUntil(timeout: .seconds(4)) {
            await sessions.count() == 1 && !manager.saving
        }

        let salvageRows = await recordings.snapshot()
        let row = try XCTUnwrap(salvageRows.first?.row)
        XCTAssertEqual(row.note, "Recovered after connection loss")
        XCTAssertGreaterThan(row.samples.count, 1)
        XCTAssertEqual(manager.status, .idle)
    }

    private func shortFakeScript(_ scenario: FakeTindeqScenario = .pull) -> FakeTindeqScript {
        FakeTindeqScript(
            scenario: scenario,
            waveform: FakeTindeqWaveform(
                configuration: FakeTindeqWaveformConfiguration(
                    baselineKg: 0.2,
                    peakKg: 12,
                    rampMs: 400,
                    holdMs: 600,
                    releaseMs: 2_400,
                    restMs: 1_800,
                    sampleIntervalMs: 20,
                    noiseKg: 0,
                    seed: 567
                )
            )
        )
    }
#endif

    private func feed(_ manager: TindeqManager, _ samples: [(Float, UInt32)]) {
        var data = Data([0x01, UInt8(samples.count * 8)])
        for (kg, us) in samples {
            withUnsafeBytes(of: kg.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: us.littleEndian) { data.append(contentsOf: $0) }
        }
        manager.handleNotification(data)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else {
                XCTFail("timed out waiting for manager state")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor RecordingQueueSpy: TindeqRecordingQueueing {
    private var items: [PendingTindeqRecording] = []
    private let outcome: QueuePersistOutcome

    init(outcome: QueuePersistOutcome = .queued) {
        self.outcome = outcome
    }

    func enqueue(_ pending: PendingTindeqRecording) async -> QueuePersistOutcome {
        items.append(pending)
        return outcome
    }

    func count() -> Int { items.count }
    func snapshot() -> [PendingTindeqRecording] { items }
}

private actor BlockingRecordingQueueSpy: TindeqRecordingQueueing {
    private var items: [PendingTindeqRecording] = []
    private var waiters: [CheckedContinuation<QueuePersistOutcome, Never>] = []

    func enqueue(_ pending: PendingTindeqRecording) async -> QueuePersistOutcome {
        items.append(pending)
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func count() -> Int { items.count }
    func snapshot() -> [PendingTindeqRecording] { items }

    func releaseAll() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: .queued) }
    }
}

private actor SessionQueueSpy: TindeqSessionQueueing {
    private var items: [PendingTindeqSession] = []

    func enqueue(_ pending: PendingTindeqSession) async -> QueuePersistOutcome {
        items.append(pending)
        return .queued
    }

    func count() -> Int { items.count }
    func snapshot() -> [PendingTindeqSession] { items }
}
