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

    func enqueue(_ pending: PendingTindeqRecording) async -> QueuePersistOutcome {
        items.append(pending)
        return .queued
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
