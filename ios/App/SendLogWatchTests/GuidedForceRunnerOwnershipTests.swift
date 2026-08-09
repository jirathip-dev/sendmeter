import Foundation
import SendLogWatchCore
import XCTest
@testable import SendLogWatch_Watch_App

private actor OwnershipRecordingQueue: TindeqRecordingQueueing {
    private var items: [PendingTindeqRecording] = []

    func enqueue(_ pending: PendingTindeqRecording) async -> QueuePersistOutcome {
        items.append(pending)
        return .queued
    }

    func count() -> Int { items.count }
}

private actor OwnershipSessionQueue: TindeqSessionQueueing {
    private var items: [PendingTindeqSession] = []

    func enqueue(_ pending: PendingTindeqSession) async -> QueuePersistOutcome {
        items.append(pending)
        return .queued
    }

    func count() -> Int { items.count }
}

@MainActor
final class GuidedForceRunnerOwnershipTests: XCTestCase {
    func testAccountChangeDiscardsActiveMeasuredClaimWithoutSaving() async {
        let accountA = UUID()
        let accountB = UUID()
        let recordingQueue = OwnershipRecordingQueue()
        let sessionQueue = OwnershipSessionQueue()
        let manager = TindeqManager(
            recordingQueue: recordingQueue,
            sessionQueue: sessionQueue,
            commandWriter: { _ in }
        )
        let runner = GuidedForceRunner(userIdProvider: { accountA })

        XCTAssertTrue(
            runner.start(
                protocolValue: movementProtocol,
                tag: "Half crimp",
                side: "left",
                manager: manager
            )
        )
        runner.advance(to: Date().addingTimeInterval(1))
        feed(manager, [(12, 0), (25, 100_000)])
        XCTAssertEqual(runner.ownerUserId, accountA)
        XCTAssertTrue(runner.isMeasured)
        XCTAssertEqual(manager.status, .measuring)

        runner.authStateDidChange(to: .signedIn(userId: accountB, tokenFresh: true))

        XCTAssertFalse(runner.isActive)
        XCTAssertNil(runner.runState)
        XCTAssertNil(runner.ownerUserId)
        XCTAssertEqual(runner.phase, .failed)
        XCTAssertEqual(
            runner.errorMessage,
            "Protocol discarded because the signed-in account changed."
        )
        XCTAssertEqual(manager.status, .idle)
        XCTAssertNil(manager.sessionId)
        XCTAssertEqual(manager.sessionCount, 0)
        let recordingCountAfterDiscard = await recordingQueue.count()
        let sessionCountAfterDiscard = await sessionQueue.count()
        XCTAssertEqual(recordingCountAfterDiscard, 0)
        XCTAssertEqual(sessionCountAfterDiscard, 0)

        // A late BLE callback must remain inside the explicit no-save seam.
        manager.handleTransportDisconnect(
            error: NSError(domain: "BLE", code: -1),
            wasIntentionalOverride: false
        )
        let recordingCountAfterLateCallback = await recordingQueue.count()
        let sessionCountAfterLateCallback = await sessionQueue.count()
        XCTAssertEqual(recordingCountAfterLateCallback, 0)
        XCTAssertEqual(sessionCountAfterLateCallback, 0)
        XCTAssertTrue(manager.recentSamples().isEmpty)
    }

    func testSignedOutDiscardsActiveRunAndSameUserTokenRefreshDoesNot() async {
        let account = UUID()
        let recordingQueue = OwnershipRecordingQueue()
        let sessionQueue = OwnershipSessionQueue()
        let manager = TindeqManager(
            recordingQueue: recordingQueue,
            sessionQueue: sessionQueue,
            commandWriter: { _ in }
        )
        let runner = GuidedForceRunner(userIdProvider: { account })

        XCTAssertTrue(
            runner.start(
                protocolValue: movementProtocol,
                tag: "Half crimp",
                side: "left",
                manager: manager
            )
        )
        runner.advance(to: Date().addingTimeInterval(1))
        runner.authStateDidChange(to: .signedIn(userId: account, tokenFresh: false))

        XCTAssertTrue(runner.isActive, "token expiry for the same account must preserve the offline run")
        XCTAssertEqual(runner.ownerUserId, account)
        XCTAssertEqual(manager.status, .measuring)

        runner.authStateDidChange(to: .signedOut)

        XCTAssertFalse(runner.isActive)
        XCTAssertNil(runner.runState)
        XCTAssertEqual(manager.status, .idle)
        let recordingCountAfterSignOut = await recordingQueue.count()
        let sessionCountAfterSignOut = await sessionQueue.count()
        XCTAssertEqual(recordingCountAfterSignOut, 0)
        XCTAssertEqual(sessionCountAfterSignOut, 0)
    }

    func testAccountChangeDiscardsActiveCadenceRunWithoutSaving() async {
        let accountA = UUID()
        let accountB = UUID()
        let recordingQueue = OwnershipRecordingQueue()
        let sessionQueue = OwnershipSessionQueue()
        let manager = TindeqManager(
            recordingQueue: recordingQueue,
            sessionQueue: sessionQueue
        )
        let runner = GuidedForceRunner(userIdProvider: { accountA })

        XCTAssertTrue(
            runner.start(
                protocolValue: movementProtocol,
                tag: "Half crimp",
                side: "left",
                manager: manager
            )
        )
        XCTAssertTrue(runner.isCadenceOnly)
        XCTAssertTrue(runner.isActive)

        runner.authStateDidChange(to: .signedIn(userId: accountB, tokenFresh: true))

        XCTAssertFalse(runner.isActive)
        XCTAssertEqual(runner.phase, .failed)
        XCTAssertEqual(manager.status, .idle)
        XCTAssertNil(manager.sessionId)
        XCTAssertEqual(manager.sessionCount, 0)
        let recordingCountAfterCadenceDiscard = await recordingQueue.count()
        let sessionCountAfterCadenceDiscard = await sessionQueue.count()
        XCTAssertEqual(recordingCountAfterCadenceDiscard, 0)
        XCTAssertEqual(sessionCountAfterCadenceDiscard, 0)
    }

    func testSignedOutCannotStartGuidedRunWithoutStableOwner() async {
        let recordingQueue = OwnershipRecordingQueue()
        let sessionQueue = OwnershipSessionQueue()
        let manager = TindeqManager(
            recordingQueue: recordingQueue,
            sessionQueue: sessionQueue,
            commandWriter: { _ in }
        )
        let runner = GuidedForceRunner(userIdProvider: { nil })

        XCTAssertFalse(
            runner.start(
                protocolValue: movementProtocol,
                tag: "Half crimp",
                side: "left",
                manager: manager
            )
        )
        XCTAssertFalse(runner.isActive)
        XCTAssertEqual(runner.phase, .failed)
        XCTAssertEqual(
            runner.errorMessage,
            "Sign in on your iPhone before starting a guided Force protocol."
        )
        XCTAssertNil(runner.ownerUserId)
        XCTAssertEqual(manager.status, .connected)
        let recordingCountAfterRejectedStart = await recordingQueue.count()
        let sessionCountAfterRejectedStart = await sessionQueue.count()
        XCTAssertEqual(recordingCountAfterRejectedStart, 0)
        XCTAssertEqual(sessionCountAfterRejectedStart, 0)
    }

    func testAccountChangeInvalidatesBlockedRecordingCompletionAndKeepsOwnerStamp() async throws {
        let accountA = UUID()
        let accountB = UUID()
        let recordingQueue = BlockingOwnershipRecordingQueue()
        let sessionQueue = OwnershipSessionQueue()
        var commands: [Tindeq.Cmd] = []
        let manager = TindeqManager(
            recordingQueue: recordingQueue,
            sessionQueue: sessionQueue,
            commandWriter: { commands.append($0) },
            userIdProvider: { accountA }
        )
        let runner = GuidedForceRunner(userIdProvider: { accountA })
        let protocolValue = blockedMovementProtocol

        XCTAssertTrue(
            runner.start(
                protocolValue: protocolValue,
                tag: "Half crimp",
                side: "left",
                manager: manager
            )
        )
        let startedAt = try XCTUnwrap(runner.runState?.startedAt)
        feed(manager, [(12, 0), (25, 100_000)])
        runner.advance(to: startedAt.addingTimeInterval(4.1))
        try await waitUntil { await recordingQueue.count() == 1 && manager.saving }

        // Set 1 is queued but the runner remains in set-rest. Switching
        // accounts must invalidate the completion before it can finish the
        // old session under B.
        runner.authStateDidChange(to: .signedIn(userId: accountB, tokenFresh: true))

        XCTAssertFalse(runner.isActive)
        XCTAssertNil(manager.sessionId)
        XCTAssertEqual(manager.sessionCount, 0)
        XCTAssertFalse(manager.saving)
        let pendingRows = await recordingQueue.snapshot()
        let pending = try XCTUnwrap(pendingRows.first)
        XCTAssertEqual(pending.enqueuedUserId, accountA)
        let sessionCountBeforeRelease = await sessionQueue.count()
        XCTAssertEqual(sessionCountBeforeRelease, 0)

        await recordingQueue.releaseAll()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(manager.sessionCount, 0)
        XCTAssertNil(manager.sessionId)
        let sessionCountAfterRelease = await sessionQueue.count()
        XCTAssertEqual(sessionCountAfterRelease, 0)
        XCTAssertEqual(commands, [.startWeight, .stop])
    }

    func testPendingSessionOwnerStampSurvivesAccountSwitchBeforeQueueActor() async throws {
        let accountA = UUID()
        let sessions = BlockingOwnershipSessionQueue()
        let manager = TindeqManager(
            recordingQueue: OwnershipRecordingQueue(),
            sessionQueue: sessions,
            userIdProvider: { accountA }
        )
        _ = manager.ensureSession()
        manager.sessionCount = 1
        manager.logSessionNow()
        try await waitUntil { await sessions.count() == 1 }

        manager.discardWithoutSaving()
        let pendingSessions = await sessions.snapshot()
        let pending = try XCTUnwrap(pendingSessions.first)
        XCTAssertEqual(pending.enqueuedUserId, accountA)
        XCTAssertNil(manager.sessionId)
        XCTAssertEqual(manager.sessionCount, 0)

        await sessions.releaseAll()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(manager.errorMsg)
        XCTAssertEqual(manager.sessionCount, 0)
    }

    func testLateAccountChangeAfterCompletedRunKeepsTerminalResult() async throws {
        let accountA = UUID()
        let accountB = UUID()
        let recordingQueue = OwnershipRecordingQueue()
        let sessionQueue = OwnershipSessionQueue()
        let manager = TindeqManager(
            recordingQueue: recordingQueue,
            sessionQueue: sessionQueue,
            commandWriter: { _ in },
            userIdProvider: { accountA }
        )
        let runner = GuidedForceRunner(userIdProvider: { accountA })

        XCTAssertTrue(
            runner.start(
                protocolValue: movementProtocol,
                tag: "Half crimp",
                side: "left",
                manager: manager
            )
        )
        let startedAt = try XCTUnwrap(runner.runState?.startedAt)
        feed(manager, [(12, 0), (25, 100_000)])
        runner.advance(to: startedAt.addingTimeInterval(movementProtocol.durationS))
        try await waitUntil { manager.sessionCount == 1 && !manager.saving }
        try await waitUntil { await sessionQueue.count() == 1 }

        XCTAssertEqual(runner.phase, .completed)
        XCTAssertNil(runner.errorMessage)
        let completion = runner.completionMessage

        runner.authStateDidChange(to: .signedIn(userId: accountB, tokenFresh: true))

        XCTAssertEqual(runner.phase, .completed)
        XCTAssertNil(runner.errorMessage)
        XCTAssertEqual(runner.completionMessage, completion)
        XCTAssertNil(runner.ownerUserId)
    }

    private var movementProtocol: WatchForceProtocol {
        WatchForceProtocol(
            id: "ownership-movement",
            name: "Ownership movement",
            holdS: 0,
            reps: 1,
            sets: 1,
            restRepsS: 0,
            restSetsS: 0,
            mode: .reverseAction,
            cadenceOutS: 3,
            cadenceReturnS: 1,
            prepareS: 0
        )
    }

    private var blockedMovementProtocol: WatchForceProtocol {
        WatchForceProtocol(
            id: "ownership-blocked-movement",
            name: "Ownership blocked movement",
            holdS: 0,
            reps: 1,
            sets: 2,
            restRepsS: 0,
            restSetsS: 10,
            mode: .reverseAction,
            cadenceOutS: 3,
            cadenceReturnS: 1,
            prepareS: 0
        )
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

private actor BlockingOwnershipRecordingQueue: TindeqRecordingQueueing {
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

private actor BlockingOwnershipSessionQueue: TindeqSessionQueueing {
    private var items: [PendingTindeqSession] = []
    private var waiters: [CheckedContinuation<QueuePersistOutcome, Never>] = []

    func enqueue(_ pending: PendingTindeqSession) async -> QueuePersistOutcome {
        items.append(pending)
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func count() -> Int { items.count }
    func snapshot() -> [PendingTindeqSession] { items }

    func releaseAll() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: .queued) }
    }
}
