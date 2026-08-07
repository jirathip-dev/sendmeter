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
        XCTAssertEqual(manager.handsFreeState, .recording(belowSinceMs: nil))

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
        XCTAssertEqual(first.peakKg, 30, accuracy: 0.01)
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
        manager.stopAndSave()
        manager.stopAndSave() // near-simultaneous duplicate loses the sync claim

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
        manager.stopAndSave()
        manager.stopAndSave()
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
        manager.stopAndSave()
        try await waitUntil { manager.sessionCount == 2 && !manager.saving }
        XCTAssertEqual(manager.handsFreeState, .waitingForSlack)
        feed(manager, [(35, 3_300_000), (35, 4_000_000)])
        XCTAssertEqual(manager.status, .connected)
        XCTAssertEqual(manager.handsFreeState, .waitingForSlack)
        let rowsWhileStillLoaded = await recordings.count()
        XCTAssertEqual(rowsWhileStillLoaded, 2)
        XCTAssertEqual(commands, [.startWeight, .stop, .startWeight, .stop, .startWeight])
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
        manager.stopAndSave()
        try await waitUntil { manager.sessionCount == 1 && !manager.saving }
        XCTAssertEqual(manager.handsFreeState, .waitingForSlack)

        // No more samples: only the wall-clock Timer can disarm this stream.
        try await waitUntil { !manager.handsFreeRequested }
        XCTAssertEqual(manager.handsFreeState, .idle)
        XCTAssertEqual(manager.savedMsg, "Hands-free disarmed after 10 min idle")
        XCTAssertEqual(commands, [.startWeight, .stop, .startWeight, .stop])
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
            )
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

private actor SessionQueueSpy: TindeqSessionQueueing {
    private var items: [PendingTindeqSession] = []

    func enqueue(_ pending: PendingTindeqSession) async -> QueuePersistOutcome {
        items.append(pending)
        return .queued
    }

    func count() -> Int { items.count }
    func snapshot() -> [PendingTindeqSession] { items }
}
