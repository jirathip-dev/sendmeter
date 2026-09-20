import Foundation
import XCTest
@testable import SendmeterCore

/// #936: the manual-workout lifecycle has ONE explicit owner, and these tests
/// drive that owner with an INJECTED clock and INJECTED effects.
///
/// They assert the owner's decisions, its workout state and the effect list it
/// hands the app — never source text — and they need no HealthKit, no Bluetooth,
/// no simulator and no ActivityKit: the card and the rest deadline are values
/// here, so a deterministic run can see exactly what the app was asked to do.
final class ManualWorkoutLifecycleCoordinatorTests: XCTestCase {
    private let account = UUID()
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Start

    func testStartCoordinatesTheWorkoutAndItsRestAndCardEffects() throws {
        var owner = ManualWorkoutLifecycleCoordinator(restTarget: 60)

        let outcome = owner.start(
            accountUserID: account,
            phase: .power,
            at: start
        )

        let workout = try XCTUnwrap(owner.workout)
        XCTAssertEqual(outcome.decision, .changed)
        XCTAssertEqual(workout.draft.accountUserID, account, "the workout belongs to the starting account")
        XCTAssertEqual(workout.draft.phase, .power)
        XCTAssertEqual(workout.draft.startedAt, start, "the injected instant is the workout's identity")
        XCTAssertEqual(workout.attemptStartedAt, nil)
        XCTAssertEqual(owner.workoutStartedAt, start)
        XCTAssertFalse(owner.isSaving)
        XCTAssertEqual(
            outcome.effects,
            [
                .syncActivity(workout: workout, restTarget: 60),
                .syncRest(workout: workout, restTarget: 60),
                .requestRestNotificationPermission,
            ],
            "a user-initiated start follows the card and the rest deadline, then asks once for permission"
        )
    }

    func testStartWithoutAPermissionPromptKeepsTheOtherEffectsInOrder() {
        var owner = ManualWorkoutLifecycleCoordinator()

        let outcome = owner.start(
            accountUserID: account,
            phase: .execution,
            at: start,
            asksForRestNotificationPermission: false
        )

        XCTAssertEqual(
            outcome.effects,
            [
                .syncActivity(workout: owner.workout, restTarget: ManualWorkoutRest.defaultRestTarget),
                .syncRest(workout: owner.workout, restTarget: ManualWorkoutRest.defaultRestTarget),
            ],
            "a harness that cannot show a system prompt skips only the permission ask"
        )
    }

    // MARK: - View recreation

    func testRecreatedViewResumesTheWorkoutInsteadOfRecreatingOrTerminatingIt() throws {
        var owner = ManualWorkoutLifecycleCoordinator(restTarget: 120)
        _ = owner.start(accountUserID: account, phase: .power, at: start)
        let running = try XCTUnwrap(owner.workout)

        // A re-created view resumes: same workout, same identity, no new work.
        let resumed = owner.resume()

        XCTAssertEqual(resumed.decision, .changed)
        XCTAssertEqual(owner.workout, running, "resume must hand back the SAME workout")
        XCTAssertEqual(
            owner.workoutStartedAt,
            start,
            "the identity the lock-screen queue and the card are keyed by is unchanged"
        )
        XCTAssertEqual(
            resumed.effects,
            [
                .syncActivity(workout: running, restTarget: 120),
                .syncRest(workout: running, restTarget: 120),
            ]
        )

        // ...and the re-created view cannot start a second workout, which would
        // both recreate the workout and orphan the first one's effects.
        let restarted = owner.start(accountUserID: account, phase: .power, at: start.addingTimeInterval(300))

        XCTAssertEqual(restarted.decision, .ignored)
        XCTAssertEqual(restarted.effects, [])
        XCTAssertEqual(owner.workout, running, "a start during an in-progress workout is ignored")
    }

    func testResumeWithNoWorkoutCreatesNothingAndTerminatesNothing() {
        var owner = ManualWorkoutLifecycleCoordinator()

        let outcome = owner.resume()

        XCTAssertEqual(outcome, .ignored, "an empty owner has nothing to resume")
        XCTAssertNil(owner.workout)
        XCTAssertNil(owner.workoutStartedAt)
    }

    func testMinimizeKeepsTheWorkoutAndDropsOnlyItsExplanation() throws {
        var owner = ManualWorkoutLifecycleCoordinator()
        _ = owner.start(accountUserID: account, phase: .power, at: start)
        let running = try XCTUnwrap(owner.workout)
        _ = owner.end(at: start.addingTimeInterval(30))
        XCTAssertEqual(owner.refusalMessage, UserFacingError.message(for: .missingAttempt))

        let outcome = owner.minimize()

        XCTAssertEqual(outcome.decision, .changed)
        XCTAssertEqual(outcome.effects, [], "minimizing neither stops the rest deadline nor ends the card")
        XCTAssertEqual(owner.workout, running, "the workout stays armed for the tab's Open full screen")
        XCTAssertNil(owner.refusalMessage, "the explanation belonged to the presentation that showed it")
    }

    // MARK: - Attempts

    func testAttemptTransitionsMutateTheOwnerFromTheInjectedClockOnly() throws {
        var owner = ManualWorkoutLifecycleCoordinator(restTarget: 180)
        _ = owner.start(accountUserID: account, phase: .power, at: start)
        let running = try XCTUnwrap(owner.workout)

        let begun = try owner.toggleAttempt(at: start.addingTimeInterval(10))

        XCTAssertEqual(begun.decision, .changed)
        XCTAssertEqual(
            owner.workout?.attemptStartedAt,
            start.addingTimeInterval(10),
            "the attempt starts at the injected instant, not at the wall clock"
        )
        XCTAssertEqual(owner.workout?.draft.startedAt, running.draft.startedAt)
        XCTAssertEqual(
            begun.effects,
            [
                .syncActivity(workout: owner.workout, restTarget: 180),
                .syncRest(workout: owner.workout, restTarget: 180),
            ],
            "the card's phase and the rest deadline follow the attempt"
        )

        let done = try owner.toggleAttempt(at: start.addingTimeInterval(70))

        XCTAssertEqual(done.decision, .changed)
        XCTAssertNil(owner.workout?.attemptStartedAt)
        XCTAssertEqual(owner.workout?.draft.attempts.count, 1)
        XCTAssertEqual(
            owner.workout?.draft.attempts.first?.durationSeconds,
            60,
            "the attempt's duration is measured between the two injected instants"
        )
    }

    func testAnInvalidAttemptTransitionLeavesTheWorkoutExactlyAsItWas() throws {
        var owner = ManualWorkoutLifecycleCoordinator()
        _ = owner.start(accountUserID: account, phase: .power, at: start)
        let running = try XCTUnwrap(owner.workout)

        XCTAssertThrowsError(try owner.toggleAttempt(at: start.addingTimeInterval(-1))) { error in
            XCTAssertEqual(error as? WorkoutEngineError, .invalidEndTime)
        }

        XCTAssertEqual(owner.workout, running, "a refused attempt transition is not half-applied")
    }

    // MARK: - Refused End (#926)

    func testEndWithNoCompletedAttemptIsRefusedAndLeavesTheWorkoutArmed() throws {
        var owner = ManualWorkoutLifecycleCoordinator()
        _ = owner.start(accountUserID: account, phase: .power, at: start)
        let running = try XCTUnwrap(owner.workout)

        let outcome = owner.end(at: start.addingTimeInterval(30))

        XCTAssertEqual(
            outcome.decision,
            .refused(message: UserFacingError.message(for: .missingAttempt)),
            "the refusal carries the #926 explanation, in the fixed product copy"
        )
        XCTAssertEqual(outcome.effects, [], "a refused End changes nothing the app must apply")
        XCTAssertEqual(owner.workout, running, "the refused workout is still armed")
        XCTAssertEqual(owner.refusalMessage, UserFacingError.message(for: .missingAttempt))
        XCTAssertFalse(owner.isSaving, "a refused End never starts a save")

        // A repeat tap must explain itself again rather than reusing stale state.
        let repeated = owner.end(at: start.addingTimeInterval(45))
        XCTAssertEqual(repeated.decision, .refused(message: UserFacingError.message(for: .missingAttempt)))
        XCTAssertEqual(owner.workout, running)
    }

    func testAnAttemptThatMovedOnDropsTheObsoleteExplanation() throws {
        var owner = ManualWorkoutLifecycleCoordinator()
        _ = owner.start(accountUserID: account, phase: .power, at: start)
        _ = owner.end(at: start.addingTimeInterval(30))
        XCTAssertNotNil(owner.refusalMessage)

        _ = try owner.toggleAttempt(at: start.addingTimeInterval(40))

        XCTAssertNil(owner.refusalMessage)
    }

    // MARK: - Accepted End: exactly one save

    func testValidFinishHandsOverExactlyOneDraftAndTearsTheEffectsDown() throws {
        var owner = ManualWorkoutLifecycleCoordinator(restTarget: 120)
        _ = owner.start(accountUserID: account, phase: .power, at: start)
        _ = try owner.toggleAttempt(at: start.addingTimeInterval(10))
        _ = try owner.toggleAttempt(at: start.addingTimeInterval(70))
        let endAt = start.addingTimeInterval(600)

        let outcome = owner.end(at: endAt)

        guard case let .persist(draft, ticket) = outcome.decision else {
            return XCTFail("an End with a completed attempt must hand over one draft, got \(outcome.decision)")
        }
        XCTAssertEqual(draft.accountUserID, account)
        XCTAssertEqual(draft.attempts.count, 1)
        XCTAssertEqual(draft.endedAt, endAt)
        XCTAssertEqual(
            outcome.effects,
            [
                .syncActivity(workout: nil, restTarget: 120),
                .discardActivityEvents,
                .syncRest(workout: nil, restTarget: 120),
            ],
            "the accepted finish ends the card, discards the workout's queued actions and stops the rest deadline"
        )
        XCTAssertNil(owner.workout, "the accepted finish clears the workout")
        XCTAssertNil(owner.workoutStartedAt)
        XCTAssertTrue(owner.isSaving, "the save the owner handed over is in flight")

        let completed = owner.saveDidComplete(ticket: ticket)
        XCTAssertEqual(completed.decision, .changed)
        XCTAssertFalse(owner.isSaving)
    }

    func testRepeatedEndNeverHandsOverASecondDraft() throws {
        var owner = ManualWorkoutLifecycleCoordinator()
        _ = owner.start(accountUserID: account, phase: .power, at: start)
        _ = try owner.toggleAttempt(at: start.addingTimeInterval(10))
        _ = try owner.toggleAttempt(at: start.addingTimeInterval(70))
        var persisted: [UUID] = []
        var ticket: UUID?

        func record(_ decision: ManualWorkoutLifecycleDecision) {
            if case let .persist(draft, handedOver) = decision {
                persisted.append(draft.sessionID)
                ticket = handedOver
            }
        }

        record(owner.end(at: start.addingTimeInterval(600)).decision)
        // A repeated tap, a re-created view's End, a second presentation — all
        // find nothing left to finish.
        record(owner.end(at: start.addingTimeInterval(60_000)).decision)
        record(owner.minimize().decision)
        record(owner.end(at: start.addingTimeInterval(120_000)).decision)

        XCTAssertEqual(persisted.count, 1, "the workout can be persisted exactly once")

        // Even after the save completes, an End has nothing to hand over.
        record(owner.saveDidComplete(ticket: try XCTUnwrap(ticket)).decision)
        record(owner.end(at: start.addingTimeInterval(180_000)).decision)
        XCTAssertEqual(persisted.count, 1)
    }

    func testALateOrStaleSaveCompletionNeverReleasesANewerFinish() throws {
        var owner = ManualWorkoutLifecycleCoordinator()
        _ = owner.start(accountUserID: account, phase: .power, at: start)
        _ = try owner.toggleAttempt(at: start.addingTimeInterval(10))
        _ = try owner.toggleAttempt(at: start.addingTimeInterval(70))
        guard case let .persist(_, ticket) = owner.end(at: start.addingTimeInterval(600)).decision else {
            return XCTFail("the finish must hand over a ticket")
        }

        let stale = owner.saveDidComplete(ticket: UUID())

        XCTAssertEqual(stale.decision, .ignored, "a stale completion is not this finish's completion")
        XCTAssertEqual(stale.effects, [])
        XCTAssertTrue(owner.isSaving, "the in-flight save stays in flight")

        XCTAssertEqual(owner.saveDidComplete(ticket: ticket).decision, .changed)
        XCTAssertEqual(
            owner.saveDidComplete(ticket: ticket).decision,
            .ignored,
            "a second completion for the same ticket is a no-op"
        )
    }

    func testStartIsIgnoredWhileThePreviousFinishIsSavingAndAllowedAfterItCompletes() throws {
        var owner = ManualWorkoutLifecycleCoordinator()
        _ = owner.start(accountUserID: account, phase: .power, at: start)
        _ = try owner.toggleAttempt(at: start.addingTimeInterval(10))
        _ = try owner.toggleAttempt(at: start.addingTimeInterval(70))
        guard case let .persist(_, ticket) = owner.end(at: start.addingTimeInterval(600)).decision else {
            return XCTFail("the finish must hand over a ticket")
        }

        let duringSave = owner.start(
            accountUserID: account,
            phase: .power,
            at: start.addingTimeInterval(601)
        )

        XCTAssertEqual(duringSave.decision, .ignored)
        XCTAssertEqual(duringSave.effects, [])
        XCTAssertNil(
            owner.workout,
            "the in-flight save's workout is not resurrected by a start"
        )

        _ = owner.saveDidComplete(ticket: ticket)
        let afterSave = owner.start(
            accountUserID: account,
            phase: .power,
            at: start.addingTimeInterval(602)
        )

        XCTAssertEqual(afterSave.decision, .changed)
        XCTAssertEqual(owner.workoutStartedAt, start.addingTimeInterval(602))
    }

    // MARK: - Rest target

    func testRestTargetChangesFollowTheValidatedTargetInTheEffects() throws {
        var owner = ManualWorkoutLifecycleCoordinator(restTarget: 180)
        _ = owner.start(accountUserID: account, phase: .power, at: start)

        let changed = owner.setRestTarget(60)

        XCTAssertEqual(changed.decision, .changed)
        XCTAssertEqual(
            changed.effects,
            [
                .syncActivity(workout: owner.workout, restTarget: 60),
                .syncRest(workout: owner.workout, restTarget: 60),
            ]
        )
        XCTAssertEqual(owner.setRestTarget(60).decision, .ignored, "the same target asks for nothing")

        let coerced = owner.setRestTarget(7)
        XCTAssertEqual(owner.restTarget, ManualWorkoutRest.defaultRestTarget)
        XCTAssertEqual(
            coerced.effects,
            [
                .syncActivity(workout: owner.workout, restTarget: ManualWorkoutRest.defaultRestTarget),
                .syncRest(workout: owner.workout, restTarget: ManualWorkoutRest.defaultRestTarget),
            ],
            "an unrecognized target resolves to the default, never to an arbitrary value"
        )
    }

    // MARK: - Lock-screen replay

    func testLockScreenReplayAppliesOnlyTheCurrentWorkoutsEvents() throws {
        var owner = ManualWorkoutLifecycleCoordinator(restTarget: 120)
        _ = owner.start(accountUserID: account, phase: .power, at: start)
        let running = try XCTUnwrap(owner.workout)

        let outcome = owner.applyActivityEvents([
            ManualWorkoutActivityEvent(
                workoutStartedAt: start,
                action: .beginBoulder,
                at: start.addingTimeInterval(12)
            ),
            // A stale workout's event is filtered by identity even if the
            // adapter ever handed it over.
            ManualWorkoutActivityEvent(
                workoutStartedAt: start.addingTimeInterval(-9_999),
                action: .endBoulder,
                at: start.addingTimeInterval(13)
            ),
        ])

        XCTAssertEqual(outcome.decision, .changed)
        XCTAssertEqual(owner.workout?.attemptStartedAt, start.addingTimeInterval(12))
        XCTAssertEqual(owner.workout?.draft.attempts.count, 0)
        XCTAssertEqual(owner.workout?.draft.startedAt, running.draft.startedAt)

        XCTAssertEqual(
            owner.applyActivityEvents([
                ManualWorkoutActivityEvent(
                    workoutStartedAt: start.addingTimeInterval(-9_999),
                    action: .beginBoulder,
                    at: start.addingTimeInterval(14)
                ),
            ]),
            .ignored,
            "events for another workout never mutate this one"
        )
        XCTAssertEqual(owner.workout?.attemptStartedAt, start.addingTimeInterval(12))
    }

    // MARK: - Account boundary

    func testAccountChangeTearsDownTheOriginalOwnersWorkoutAndItsIdentity() throws {
        var owner = ManualWorkoutLifecycleCoordinator(restTarget: 60)
        _ = owner.start(accountUserID: account, phase: .power, at: start)

        let outcome = owner.accountChanged(previousAccountUserID: account)

        XCTAssertEqual(outcome.decision, .changed)
        XCTAssertEqual(
            outcome.effects,
            [
                .syncActivity(workout: nil, restTarget: 60),
                .discardActivityEvents,
                .syncRest(workout: nil, restTarget: 60),
            ],
            "the boundary ends the card, discards the workout's queued actions and stops the rest deadline"
        )
        XCTAssertNil(owner.workout)
        XCTAssertNil(owner.workoutStartedAt, "the next account's workout gets a fresh identity")
        XCTAssertFalse(owner.isSaving)

        // The torn-down workout's queued events can no longer reach anything.
        XCTAssertEqual(
            owner.applyActivityEvents([
                ManualWorkoutActivityEvent(
                    workoutStartedAt: start,
                    action: .beginBoulder,
                    at: start.addingTimeInterval(20)
                ),
            ]),
            .ignored
        )
        // ...and repeating the boundary is a no-op rather than a second teardown.
        XCTAssertEqual(owner.accountChanged(previousAccountUserID: account), .ignored)
    }

    func testAccountBoundaryForAnotherAccountLeavesTheWorkoutAlone() throws {
        var owner = ManualWorkoutLifecycleCoordinator()
        let otherAccount = UUID()
        _ = owner.start(accountUserID: account, phase: .power, at: start)
        let running = try XCTUnwrap(owner.workout)

        let outcome = owner.accountChanged(previousAccountUserID: otherAccount)

        XCTAssertEqual(outcome, .ignored, "a stale boundary never takes out the incoming account's workout")
        XCTAssertEqual(owner.workout, running)
        XCTAssertEqual(owner.workoutStartedAt, start, "its queued actions keep replaying into it")
        XCTAssertEqual(
            owner.applyActivityEvents([
                ManualWorkoutActivityEvent(
                    workoutStartedAt: start,
                    action: .beginBoulder,
                    at: start.addingTimeInterval(20)
                ),
            ]).decision,
            .changed
        )
    }

    func testTeardownDuringASaveReleasesTheLatchAndMakesTheLateCompletionANoop() throws {
        var owner = ManualWorkoutLifecycleCoordinator()
        _ = owner.start(accountUserID: account, phase: .power, at: start)
        _ = try owner.toggleAttempt(at: start.addingTimeInterval(10))
        _ = try owner.toggleAttempt(at: start.addingTimeInterval(70))
        guard case let .persist(draft, ticket) = owner.end(at: start.addingTimeInterval(600)).decision else {
            return XCTFail("the finish must hand over a ticket")
        }
        XCTAssertTrue(owner.isSaving)

        let outcome = owner.accountChanged(previousAccountUserID: draft.accountUserID)

        XCTAssertEqual(outcome.decision, .changed)
        XCTAssertFalse(owner.isSaving, "the new account's UI is never stuck behind the old account's save")
        XCTAssertEqual(
            owner.saveDidComplete(ticket: ticket),
            .ignored,
            "the torn-down save's completion is a no-op — it cannot clear a newer finish"
        )
    }

    func testAnAlreadyEmptyOwnerHasNothingToTearDown() {
        var owner = ManualWorkoutLifecycleCoordinator()

        XCTAssertEqual(owner.accountChanged(previousAccountUserID: account), .ignored)
        XCTAssertEqual(owner.accountChanged(previousAccountUserID: nil), .ignored)
    }
}
