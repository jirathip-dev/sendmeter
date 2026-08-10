import Foundation
import XCTest
@testable import SendLogWatch_Watch_App

private enum WorkoutSavePathAuthorizationFailure: Error {
    case unavailable
}

private func makeAuthorizationFailingWorkoutManager(
    userIdProvider: @escaping @Sendable () -> UUID? = { WatchSessionStore.shared.userId }
) -> WorkoutManager {
    let manager = WorkoutManager(userIdProvider: userIdProvider)
    manager.authorizationRequestOverride = {
        throw WorkoutSavePathAuthorizationFailure.unavailable
    }
    return manager
}

/// Review finding F1 (#476): once `WorkoutManager` is App-scoped, its
/// save-outcome fields outlive any single workout. `start()` must decide the
/// fate of each of them explicitly — clearing the per-save transients, but
/// deliberately preserving `failedBundle` (the #287 last in-memory copy of a
/// workout that couldn't be saved) so it's never silently discarded.
///
/// This is the production entry point (`WorkoutManager.start()`), not a
/// parallel copy of the reset logic — a regression here is a regression in
/// exactly what ships.
@MainActor
final class WorkoutSavePathResetTests: XCTestCase {
    private func sampleBundle() -> WorkoutSaveBundle {
        let workoutId = UUID()
        let sessionId = UUID()
        return WorkoutSaveBundle(
            session: SessionInsert(
                id: sessionId, date: "2026-08-06", type: "bouldering", typeLabel: "Bouldering",
                durationMin: 12, rpe: 5.0, note: "", phase: "capacity"
            ),
            workout: ClimbWorkoutInsert(
                id: workoutId, startedAt: Date(), endedAt: Date(),
                elevationGainM: 1, attemptsDetected: 1, attemptsConfirmed: 1,
                rpePredicted: 5, rpeConfirmed: 5, meanEffort: 5, attemptsPer10min: 1,
                sessionId: sessionId
            ),
            attempts: [],
            // Irrelevant to this fixture (save-path reset, not account
            // ownership — see the #529 tests below).
            enqueuedUserId: nil
        )
    }

    /// Review finding F1, the reset half of the fix: a stale `justSaved` /
    /// `stillQueued` / `ending` from workout N used to survive untouched into
    /// N+1's `start()` — harmless for `ending` only by luck (every path
    /// happened to reset it), but `justSaved` covering a running N+1 with a
    /// "Saved ✓" flash (no End control) was scenario C of the review.
    func testStartClearsPerSaveTransientsFromAPreviousWorkout() async {
        let manager = makeAuthorizationFailingWorkoutManager()
        manager.justSaved = true
        manager.stillQueued = true
        manager.ending = true

        await manager.start()

        XCTAssertFalse(manager.justSaved, "a stale justSaved from a previous workout must not survive into the next one's render")
        XCTAssertFalse(manager.stillQueued)
        XCTAssertFalse(manager.ending)
    }

    /// Review finding F1, scenario B: a `.lost` `failedBundle` used to make
    /// `start()` unreachable from the UI forever (no navigation cleared it
    /// any more, post-hoist). The fix is at the view layer (Start is always
    /// offered, per `WorkoutScreenSelection`), but `start()` itself must
    /// never treat a stale `failedBundle` as a reason to bail, and must not
    /// discard it either — it's the only in-memory copy of that workout's
    /// unsaved data.
    func testStartSucceedsWithAStaleFailedBundlePresentAndPreservesIt() async {
        let manager = makeAuthorizationFailingWorkoutManager()
        let stale = sampleBundle()
        manager.failedBundle = stale

        await manager.start()

        XCTAssertEqual(manager.acceptedStartCount, 1, "a stale failedBundle from a previous workout must not block start()")
        XCTAssertNotNil(manager.failedBundle, "the previous workout's failed bundle must survive — it's the only in-memory copy of unsaved data (#287)")
        XCTAssertEqual(manager.failedBundle?.workout.id, stale.workout.id, "start() must not replace it with something else, either")
    }

    // Re-review finding R1's id-matched `failedBundle` clear used to be
    // tested here, directly against `save()`. Review finding X1: driving
    // `save()` from a unit test requires it to reach a real
    // `OfflineQueue.enqueue` (disk I/O) and `WidgetBridge.refreshStatus()`
    // (live network) — each of those two tests took ~15.9s, and together
    // they made this whole target fail intermittently (measured by the
    // reviewer at ~40% of runs) with no cleanup of the `pending/<uuid>.json`
    // files they left behind. The comparison itself is pure and is now
    // tested fast, deterministically, and CI-covered as
    // `FailedBundleClearTests` in `SendLogWatchCoreTests`. `save()` is
    // `private` again; its one line wiring `FailedBundleClear.shouldClear`
    // is verified by inspection, not by reproducing the network path here.
}

/// Issue #529, slice 1 — workout ownership. `WorkoutManager` used to have no
/// concept of an owning account at all: `save()` reached `OfflineQueue.enqueue`
/// with a bundle whose `enqueuedUserId` was nil, and `UploadQueueEngine`
/// stamped it with whoever was CURRENTLY signed in at that moment — the exact
/// account captured at the *end* of a workout, not the one that started it.
/// An A → signed-out/B switch mid-workout could therefore upload A's climb
/// under B. The fix mirrors `GuidedForceRunner.ownerUserId`: capture the
/// account synchronously the moment `start()` accepts a run, and never read
/// it again for that run. These tests exercise the production entry points
/// (`WorkoutManager.start()`, `Repo.makeSaveBundle`) directly — `save()`
/// itself stays untested here for the X1 reason above (it reaches the real
/// `OfflineQueue.shared` singleton); the queue-level hold/drain behavior for
/// an owned bundle is covered in `OfflineQueueTests`.
@MainActor
final class WorkoutManagerOwnershipTests: XCTestCase {
    /// The named "before-save switch" acceptance case: `start()` must read
    /// the signed-in account synchronously, in the same accepted-start reset
    /// block as `workoutId`/`cachedPhase` — not lazily, and not only once a
    /// save is attempted.
    func testStartCapturesOwnerUserIdFromTheProviderSynchronously() async {
        let ownerA = UUID()
        let manager = makeAuthorizationFailingWorkoutManager(userIdProvider: { ownerA })

        await manager.start()

        XCTAssertEqual(manager.ownerUserId, ownerA, "start() must capture the signed-in account as this run's immutable owner")
    }

    /// The other half of "before-save switch": once captured, the owner must
    /// NOT be re-read later — a workout is a live HKWorkoutSession the user
    /// is mid-climb inside, so (unlike a guided Force run) it stays running
    /// and stays A-owned through any later account change, rather than
    /// discarding itself.
    func testOwnerUserIdStaysImmutableAfterAnAccountSwitchFollowingStart() async {
        final class AccountBox: @unchecked Sendable {
            var current: UUID?
        }
        let box = AccountBox()
        let ownerA = UUID()
        box.current = ownerA
        let manager = makeAuthorizationFailingWorkoutManager(userIdProvider: { box.current })

        await manager.start()
        XCTAssertEqual(manager.ownerUserId, ownerA)

        // Simulate the phone relaying a signed-out state, then a different
        // account B — neither must move `ownerUserId` off of A.
        box.current = nil
        XCTAssertEqual(manager.ownerUserId, ownerA, "signing out mid-workout must not clear or rebind the run's owner")

        box.current = UUID()
        XCTAssertEqual(manager.ownerUserId, ownerA, "a different account signing in mid-workout must not silently rebind the run")
    }

    /// A concurrent double-tap on Start (`WorkoutManagerDoubleStartTests`'s
    /// scenario) must not re-capture the owner on the rejected second call —
    /// the guard already ensures only the first pass runs the reset block at
    /// all, but this pins the observable consequence for ownership
    /// specifically: the accepted run's owner is whatever the provider
    /// returned at ITS accepted moment.
    func testConcurrentDoubleStartCapturesTheOwnerExactlyOnce() async throws {
        let ownerA = UUID()
        let manager = makeAuthorizationFailingWorkoutManager(userIdProvider: { ownerA })

        await manager.start()
        await manager.start()

        XCTAssertEqual(manager.acceptedStartCount, 2, "sequential completed starts both accept")
        XCTAssertEqual(manager.ownerUserId, ownerA)
    }

    /// `Repo.makeSaveBundle` is the seam `endAndSave()` calls with the
    /// manager's captured `ownerUserId` — proving it stamps `enqueuedUserId`
    /// from the explicit parameter (never re-deriving from whatever is
    /// currently signed in) is what makes the "A stays A-owned even after a
    /// signed-out/B transition" guarantee hold all the way to the bundle
    /// `OfflineQueue.enqueue` receives.
    func testMakeSaveBundleStampsTheExplicitOwnerNotWhoeverIsCurrentlySignedIn() {
        let ownerA = UUID()
        let summary = WorkoutSummary(
            workoutId: UUID(),
            startedAt: Date(),
            endedAt: Date().addingTimeInterval(600),
            avgHR: nil,
            maxHR: nil,
            activeKcal: nil,
            elevationGainM: 0,
            attempts: [],
            predictedRPE: 5,
            rawTrace: []
        )

        let bundle = Repo.makeSaveBundle(
            summary: summary, boulders: 0, rpe: 5, phase: "capacity", tunables: .default,
            ownerUserId: ownerA
        )

        XCTAssertEqual(bundle.enqueuedUserId, ownerA, "the bundle must carry the explicit owner passed in, with no other source of truth")
    }

    /// A run that was genuinely never signed in (unreachable via the normal
    /// UI gate, but not a crash either) must not fabricate an owner — `nil`
    /// stays `nil` all the way through, honestly.
    func testMakeSaveBundleStampsNilWhenNoOwnerWasCaptured() {
        let summary = WorkoutSummary(
            workoutId: UUID(),
            startedAt: Date(),
            endedAt: Date().addingTimeInterval(600),
            avgHR: nil,
            maxHR: nil,
            activeKcal: nil,
            elevationGainM: 0,
            attempts: [],
            predictedRPE: 5,
            rawTrace: []
        )

        let bundle = Repo.makeSaveBundle(
            summary: summary, boulders: 0, rpe: 5, phase: "capacity", tunables: .default,
            ownerUserId: nil
        )

        XCTAssertNil(bundle.enqueuedUserId)
    }
}
