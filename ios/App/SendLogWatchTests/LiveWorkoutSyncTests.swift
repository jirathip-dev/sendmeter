import Foundation
import XCTest
import SendLogWatchCore
@testable import SendLogWatch_Watch_App

/// Issue #531: `LiveWorkoutSync.upsert` used to `try? await` its network
/// call — every failure was swallowed, and for the TERMINAL row specifically
/// that permanently left the server-side `live_workouts` row `status='live'`,
/// because `beat()`/`markEnded()` both refuse every later sequence once
/// `terminalQueued`, so nothing else would ever arrive to retry with. These
/// exercise the real `drain()` control flow via the injectable
/// `uploader`/`terminalRetry` seams — mirroring `OfflineQueueTests`' pattern
/// for #475/#472b — not a reimplementation of it.
final class LiveWorkoutSyncTests: XCTestCase {
    private let testUserId = UUID()

    override func setUpWithError() throws {
        // `resolveUserId()` reads `WatchSessionStore.shared` synchronously
        // (#265) — without a relayed session every `beat()`/`markEnded()`
        // call bails out before ever reaching the uploader, same as a real
        // signed-out watch. Mirrors `OfflineQueueTests.signIn`.
        WatchSessionStore.shared.store(
            RelayedSession(
                accessToken: "test-access-token-\(testUserId.uuidString)",
                userId: testUserId,
                expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970
            )
        )
    }

    override func tearDownWithError() throws {
        WatchSessionStore.shared.clear()
    }

    private func makeSync(
        upserter: RecordingUpserter,
        terminalRetry: RecordingTerminalRetryDouble,
        workoutId: UUID = UUID(),
        startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> LiveWorkoutSync {
        LiveWorkoutSync(
            workoutId: workoutId,
            startedAt: startedAt,
            uploader: upserter,
            terminalRetry: terminalRetry
        )
    }

    @discardableResult
    private func beat(
        _ sync: LiveWorkoutSync,
        sequence: Int,
        event: LiveMirrorEvent = .telemetry,
        terminal: Bool = false
    ) async -> Void {
        await sync.beat(
            hr: 120, attemptCount: 1, activeKcal: 10, elevationGainM: 2,
            climbing: false, climbingSince: nil, restStartedAt: nil, restTargetS: nil,
            sequence: sequence, event: event, terminal: terminal
        )
    }

    /// The named acceptance criterion: a failed terminal upsert must not be
    /// dropped — it is handed off, never swallowed by a `try?`.
    func testFailedTerminalUpsertIsHandedOffNotDropped() async throws {
        let upserter = RecordingUpserter(shouldFail: { _ in true })
        let terminalRetry = RecordingTerminalRetryDouble()
        let sync = makeSync(upserter: upserter, terminalRetry: terminalRetry)

        await sync.markEnded()

        let handOffs = await terminalRetry.handOffs
        XCTAssertEqual(handOffs.count, 1, "the failed terminal row must be handed off exactly once")
        XCTAssertEqual(handOffs.first?.terminal, true)
        XCTAssertEqual(handOffs.first?.status, "ended")
    }

    /// A successful terminal upsert must never reach the retry queue.
    func testSuccessfulTerminalUpsertNeverHandsOff() async throws {
        let upserter = RecordingUpserter(shouldFail: { _ in false })
        let terminalRetry = RecordingTerminalRetryDouble()
        let sync = makeSync(upserter: upserter, terminalRetry: terminalRetry)

        await sync.markEnded()

        let handOffs = await terminalRetry.handOffs
        XCTAssertTrue(handOffs.isEmpty)
        let calls = await upserter.calls
        XCTAssertEqual(calls.count, 1)
    }

    /// "Tests cover terminal request failure followed by recovery, including
    /// a failure after an earlier live row successfully reached Supabase."
    func testTerminalFailureAfterAnEarlierLiveRowSucceeded() async throws {
        let upserter = RecordingUpserter(shouldFail: { $0.terminal })
        let terminalRetry = RecordingTerminalRetryDouble()
        let sync = makeSync(upserter: upserter, terminalRetry: terminalRetry)

        await beat(sync, sequence: 1, event: .telemetry)
        await sync.markEnded()

        let calls = await upserter.calls
        XCTAssertEqual(calls.count, 2, "both the live beat and the terminal attempt must reach the uploader")
        XCTAssertEqual(calls[0].terminal, false)
        XCTAssertEqual(calls[1].terminal, true)

        let handOffs = await terminalRetry.handOffs
        XCTAssertEqual(handOffs.count, 1)
        XCTAssertEqual(handOffs.first?.sequence, calls[1].sequence)
    }

    /// "A failed telemetry upsert cannot reopen or replace an already-claimed
    /// terminal state." Once `markEnded()` has claimed the terminal sequence
    /// — even though its own upsert failed and is now queued for durable
    /// retry — `beat()` must refuse every later sequence: the failed
    /// terminal attempt is never superseded by a live beat that happens to
    /// arrive afterward.
    func testBeatAfterFailedTerminalCannotReopenOrReplaceIt() async throws {
        let upserter = RecordingUpserter(shouldFail: { _ in true })
        let terminalRetry = RecordingTerminalRetryDouble()
        let sync = makeSync(upserter: upserter, terminalRetry: terminalRetry)

        await sync.markEnded() // fails, hands off
        await beat(sync, sequence: 999, event: .telemetry) // must be refused

        let calls = await upserter.calls
        XCTAssertEqual(calls.count, 1, "only the terminal attempt may ever reach the uploader once claimed")
        XCTAssertEqual(calls.first?.terminal, true)
        let handOffs = await terminalRetry.handOffs
        XCTAssertEqual(handOffs.count, 1, "the later beat must not produce a second hand-off")
    }

    /// A second `markEnded()` call after the first already claimed (and
    /// failed) the terminal sequence must be a no-op, not a second hand-off
    /// — repeated retry after that point is driven by
    /// `LiveWorkoutTerminalRetry`, not by calling `markEnded()` again.
    func testRepeatedMarkEndedDoesNotDoubleHandOff() async throws {
        let upserter = RecordingUpserter(shouldFail: { _ in true })
        let terminalRetry = RecordingTerminalRetryDouble()
        let sync = makeSync(upserter: upserter, terminalRetry: terminalRetry)

        await sync.markEnded()
        await sync.markEnded()

        let calls = await upserter.calls
        XCTAssertEqual(calls.count, 1, "a repeated markEnded() must not resend once already claimed")
        let handOffs = await terminalRetry.handOffs
        XCTAssertEqual(handOffs.count, 1)
    }

    /// A failed TELEMETRY upsert (not terminal) must never reach the retry
    /// queue — it stays best-effort, superseded by the next beat, exactly as
    /// before #531 for this specific case.
    func testFailedTelemetryUpsertIsNotHandedOff() async throws {
        let upserter = RecordingUpserter(shouldFail: { !$0.terminal })
        let terminalRetry = RecordingTerminalRetryDouble()
        let sync = makeSync(upserter: upserter, terminalRetry: terminalRetry)

        await beat(sync, sequence: 1, event: .telemetry)

        let handOffs = await terminalRetry.handOffs
        XCTAssertTrue(handOffs.isEmpty)
    }
}

/// Records every row `LiveWorkoutSync` attempts to send, failing per a
/// scripted predicate — mirrors `ScriptedUploader` (OfflineQueueTests).
private actor RecordingUpserter: LiveWorkoutUpserting {
    private let shouldFail: @Sendable (LiveWorkoutUpsert) -> Bool
    private(set) var calls: [LiveWorkoutUpsert] = []

    init(shouldFail: @escaping @Sendable (LiveWorkoutUpsert) -> Bool) {
        self.shouldFail = shouldFail
    }

    func upsert(_ row: LiveWorkoutUpsert) async throws {
        calls.append(row)
        if shouldFail(row) {
            throw URLError(.notConnectedToInternet)
        }
    }
}

/// Records every terminal row `LiveWorkoutSync` hands off — the direct
/// observable proof that a failed terminal write is never dropped by a
/// swallowed `try?`.
private actor RecordingTerminalRetryDouble: LiveWorkoutTerminalRetrying {
    private(set) var handOffs: [LiveWorkoutUpsert] = []

    func handOff(_ row: LiveWorkoutUpsert, error: Error) async {
        handOffs.append(row)
    }
}
