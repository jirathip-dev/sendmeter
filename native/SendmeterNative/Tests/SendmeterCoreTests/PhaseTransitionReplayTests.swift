import XCTest
@testable import SendmeterCore

/// #917: the phase-transition half of the direct-write envelope — the durable
/// intent for a training-block switch (phase periods + the settings row that
/// has to point at the canonical open period), and the pure replay rules that
/// make a replayed transition converge instead of duplicating a period.
final class PhaseTransitionReplayTests: XCTestCase {
    private let today = "2026-09-19"
    private let earlierStart = "2026-09-01"

    // MARK: - Already applied (the duplicate-create guard)

    /// `phase_periods` mints its own row id on insert, so the ONLY proof that a
    /// create already landed is the server's own list. The intended block,
    /// open, with the intended start date, IS that acknowledgement.
    func testAnIntendedOpenBlockAlreadyOnTheServerCountsAsApplied() {
        let intent = Self.intent(
            targetPhase: .strength,
            settings: UserSettings(currentPhase: .strength, phaseStartDate: today),
            previousPeriods: [Self.period(phase: .capacity, startedOn: earlierStart)]
        )
        let serverPeriods = [
            Self.period(phase: .capacity, startedOn: earlierStart, endedOn: today),
            Self.period(phase: .strength, startedOn: today),
        ]

        XCTAssertTrue(
            PhaseTransitionReplayPolicy.isApplied(intent: intent, serverPeriods: serverPeriods),
            "a landed create is recognized from the server row, not re-inserted"
        )
    }

    func testAnOpenBlockOfTheWrongPhaseOrDateIsNotApplied() {
        let intent = Self.intent(
            targetPhase: .strength,
            settings: UserSettings(currentPhase: .strength, phaseStartDate: today),
            previousPeriods: [Self.period(phase: .capacity, startedOn: earlierStart)]
        )

        XCTAssertFalse(
            PhaseTransitionReplayPolicy.isApplied(
                intent: intent,
                serverPeriods: [Self.period(phase: .capacity, startedOn: earlierStart)]
            ),
            "the transition has not run: the old block is still the open one"
        )
        XCTAssertFalse(
            PhaseTransitionReplayPolicy.isApplied(
                intent: intent,
                serverPeriods: [Self.period(phase: .strength, startedOn: earlierStart)]
            ),
            "same phase, different block start: not this transition's period"
        )
    }

    /// The strictness that keeps a half-applied transition visible: two open
    /// periods are not the intended end state, so the replay must report
    /// incompleteness instead of confirming it.
    func testTwoOpenPeriodsAreNeverAppliedOrComplete() {
        let intent = Self.intent(
            targetPhase: .strength,
            settings: UserSettings(currentPhase: .strength, phaseStartDate: today),
            previousPeriods: [Self.period(phase: .capacity, startedOn: earlierStart)]
        )
        let twoOpen = [
            Self.period(phase: .strength, startedOn: today),
            Self.period(phase: .strength, startedOn: today),
        ]

        XCTAssertFalse(PhaseTransitionReplayPolicy.isApplied(intent: intent, serverPeriods: twoOpen))
        XCTAssertFalse(PhaseTransitionReplayPolicy.isComplete(intent: intent, resultPeriods: twoOpen))
    }

    // MARK: - Planning input (the pre-state anchor)

    /// The termination window that matters most: a same-day switch-back whose
    /// `delete` landed but whose `reopen` did not. The server's own state no
    /// longer shows the open period, so re-planning from it would create a NEW
    /// period (a second block, with a fresh start date) — the intent's own
    /// pre-state is what reproduces the `reopen`.
    func testPlanInputKeepsARecoverableReopenInsteadOfCreatingASecondPeriod() {
        let open = Self.period(
            id: UUID(uuidString: "91700000-0000-4000-8000-0000000000a1")!,
            phase: .strength,
            startedOn: today
        )
        let previous = Self.period(
            id: UUID(uuidString: "91700000-0000-4000-8000-0000000000a0")!,
            phase: .capacity,
            startedOn: earlierStart,
            endedOn: today
        )
        let intent = Self.intent(
            targetPhase: .capacity,
            settings: UserSettings(currentPhase: .capacity, phaseStartDate: earlierStart),
            previousPeriods: [open, previous]
        )
        // The delete landed; the reopen did not.
        let serverPeriods = [previous]

        let input = PhaseTransitionReplayPolicy.planInput(intent: intent, serverPeriods: serverPeriods)
        XCTAssertEqual(
            input,
            [open, previous],
            "the intent's pre-state is still anchored: it describes the reopen's target"
        )
        let plan = PhaseTransitionReplayPolicy.plan(for: intent, periods: input)
        XCTAssertTrue(
            plan.mutations.contains(PhaseMutation.reopen(periodID: previous.id)),
            "the replay must reopen the previous block, not create a new one"
        )
        XCTAssertFalse(
            plan.mutations.contains { if case .create = $0 { return true } else { return false } },
            "a same-day switch-back must not mint a second period"
        )
    }

    /// A superseded transition's local preview period was never minted by the
    /// server. Re-planning from that view would PATCH nothing while the
    /// settings write still went through, so the server's own state takes over.
    func testPlanInputFallsBackToTheServerStateWhenTheViewIsNotServerAnchored() {
        // A first (offline) switch to Strength left a local preview period; a
        // second switch to Power was authored against that preview. The server
        // never saw either, so it still serves the ORIGINAL open block.
        let serverOpen = Self.period(
            id: UUID(uuidString: "91700000-0000-4000-8000-0000000000b0")!,
            phase: .capacity,
            startedOn: earlierStart
        )
        let localPreview = Self.period(
            id: UUID(uuidString: "91700000-0000-4000-8000-0000000000b1")!,
            phase: .strength,
            startedOn: today
        )
        let intent = Self.intent(
            targetPhase: .power,
            settings: UserSettings(currentPhase: .power, phaseStartDate: today),
            previousPeriods: [
                Self.period(
                    id: serverOpen.id,
                    phase: .capacity,
                    startedOn: earlierStart,
                    endedOn: today
                ),
                localPreview,
            ]
        )

        let input = PhaseTransitionReplayPolicy.planInput(
            intent: intent,
            serverPeriods: [serverOpen]
        )

        XCTAssertEqual(input, [serverOpen], "the plan must be authored against rows the server owns")
        let plan = PhaseTransitionReplayPolicy.plan(for: intent, periods: input)
        XCTAssertTrue(
            plan.mutations.contains(PhaseMutation.close(periodID: serverOpen.id, endedOn: today)),
            "the server's open block is the one to close"
        )
        XCTAssertTrue(
            plan.mutations.contains { if case .create = $0 { return true } else { return false } },
            "and the new block is created against the server's state"
        )
    }

    /// The other direction: an already-applied `delete` must not stop the
    /// pre-state from being anchored (the delete is idempotent, its absence is
    /// exactly what a landed soft delete looks like).
    func testPlanInputStaysAnchoredWhenThePlansDeleteAlreadyLanded() {
        let deleted = Self.period(
            id: UUID(uuidString: "91700000-0000-4000-8000-0000000000c1")!,
            phase: .strength,
            startedOn: today
        )
        let reopened = Self.period(
            id: UUID(uuidString: "91700000-0000-4000-8000-0000000000c0")!,
            phase: .capacity,
            startedOn: earlierStart,
            endedOn: today
        )
        let intent = Self.intent(
            targetPhase: .capacity,
            settings: UserSettings(currentPhase: .capacity, phaseStartDate: earlierStart),
            previousPeriods: [deleted, reopened]
        )

        XCTAssertTrue(
            PhaseTransitionReplayPolicy.isServerAnchored(
                intent: intent,
                serverPeriods: [reopened]
            ),
            "a delete that already landed does not un-anchor the pre-state"
        )
    }

    /// A block another writer opened, with the block the plan knows no longer
    /// on the server: the plan is not ours to apply as authored.
    func testPlanInputRejectsAnUnknownOpenBlock() {
        let mine = Self.period(
            id: UUID(uuidString: "91700000-0000-4000-8000-0000000000d0")!,
            phase: .capacity,
            startedOn: earlierStart
        )
        let theirs = Self.period(
            id: UUID(uuidString: "91700000-0000-4000-8000-0000000000d1")!,
            phase: .power,
            startedOn: today
        )
        let intent = Self.intent(
            targetPhase: .strength,
            settings: UserSettings(currentPhase: .strength, phaseStartDate: today),
            previousPeriods: [mine]
        )

        XCTAssertFalse(
            PhaseTransitionReplayPolicy.isServerAnchored(
                intent: intent,
                serverPeriods: [theirs]
            ),
            "the block this plan would close is not on the server any more"
        )
        XCTAssertEqual(
            PhaseTransitionReplayPolicy.planInput(intent: intent, serverPeriods: [theirs]),
            [theirs]
        )
    }

    /// Two open periods on the server is a state no plan can be authored
    /// against, even when one of them is the block the plan knows.
    func testPlanInputRejectsADoublyOpenServerState() {
        let mine = Self.period(
            id: UUID(uuidString: "91700000-0000-4000-8000-0000000000e0")!,
            phase: .capacity,
            startedOn: earlierStart
        )
        let theirs = Self.period(
            id: UUID(uuidString: "91700000-0000-4000-8000-0000000000e1")!,
            phase: .strength,
            startedOn: today
        )
        let intent = Self.intent(
            targetPhase: .strength,
            settings: UserSettings(currentPhase: .strength, phaseStartDate: today),
            previousPeriods: [mine]
        )

        XCTAssertFalse(
            PhaseTransitionReplayPolicy.isServerAnchored(
                intent: intent,
                serverPeriods: [mine, theirs]
            )
        )
    }

    // MARK: - Completeness

    /// The completeness check is what a partially-applied transition has to
    /// fail: the writes ran, but the open block is not the intended one.
    func testCompletenessRequiresExactlyTheIntendedOpenBlock() {
        let intent = Self.intent(
            targetPhase: .strength,
            settings: UserSettings(currentPhase: .strength, phaseStartDate: today),
            previousPeriods: [Self.period(phase: .capacity, startedOn: earlierStart)]
        )

        XCTAssertTrue(
            PhaseTransitionReplayPolicy.isComplete(
                intent: intent,
                resultPeriods: [
                    Self.period(phase: .capacity, startedOn: earlierStart, endedOn: today),
                    Self.period(phase: .strength, startedOn: today),
                ]
            )
        )
        XCTAssertFalse(
            PhaseTransitionReplayPolicy.isComplete(
                intent: intent,
                resultPeriods: [Self.period(phase: .capacity, startedOn: earlierStart)]
            ),
            "no open block: the create never landed"
        )
        XCTAssertFalse(
            PhaseTransitionReplayPolicy.isComplete(
                intent: intent,
                resultPeriods: [Self.period(phase: .strength, startedOn: earlierStart)]
            ),
            "the wrong start date is a different block: settings would mismatch history"
        )
    }

    func testCompletenessRejectsAnEmptyResult() {
        let intent = Self.intent(
            targetPhase: .strength,
            settings: UserSettings(currentPhase: .strength, phaseStartDate: today),
            previousPeriods: []
        )

        XCTAssertFalse(PhaseTransitionReplayPolicy.isComplete(intent: intent, resultPeriods: []))
    }

    // MARK: - Queue durability (the existing engine)

    /// The intent must survive process death in the EXISTING `DurableQueue`:
    /// a fresh queue instance over the same file returns the target, the date,
    /// the state the plan was authored against and the intended settings.
    func testPhaseTransitionIntentSurvivesAFreshQueueInstanceOverTheSameFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let previous = Self.period(phase: .capacity, startedOn: earlierStart)
        let intent = Self.intent(
            targetPhase: .strength,
            settings: UserSettings(currentPhase: .strength, phaseStartDate: today),
            previousPeriods: [previous]
        )

        let queue = try DurableQueue<TestPhaseTransitionPayload>(
            directoryURL: directory,
            filename: "pending-writes.json"
        )
        let enqueued = try await queue.enqueue(
            DurableQueueItem(
                id: PhaseTransitionIntent.queueItemID,
                accountUserID: user,
                terminalKey: PhaseTransitionIntent.queueItemID,
                payload: .phaseTransition(intent)
            )
        )
        XCTAssertTrue(enqueued)

        // Process death: nothing in memory survives; only the file does.
        let relaunched = try DurableQueue<TestPhaseTransitionPayload>(
            directoryURL: directory,
            filename: "pending-writes.json"
        )
        let restored = await relaunched.item(
            id: PhaseTransitionIntent.queueItemID,
            accountUserID: user
        )

        guard case let .phaseTransition(restoredIntent)? = restored?.payload else {
            return XCTFail("the phase transition intent did not survive the relaunch")
        }
        XCTAssertEqual(restored?.accountUserID, user, "the transition is account-scoped")
        XCTAssertEqual(restoredIntent.targetPhase, .strength)
        XCTAssertEqual(restoredIntent.intendedToday, today, "the intended date is immutable")
        XCTAssertEqual(restoredIntent.previousPeriods, [previous])
        XCTAssertEqual(restoredIntent.settings.currentPhase, .strength)
        XCTAssertEqual(restoredIntent.settings.phaseStartDate, today)
        XCTAssertEqual(restoredIntent.operationID, intent.operationID, "the operation identity is stable")
        let foreign = await relaunched.item(
            id: PhaseTransitionIntent.queueItemID,
            accountUserID: UUID()
        )
        XCTAssertNil(foreign, "another account sees nothing")
    }

    /// An incomplete transition must stay retryable — it is never a payload
    /// problem, and the bounded quarantine (not a silent drop) is the end of
    /// the retry budget.
    func testIncompleteTransitionIsRetryable() {
        XCTAssertEqual(
            PhaseTransitionReplayError.incompleteTransition.rejectionClass,
            .retryable
        )
    }

    // MARK: - Fixtures

    private static func intent(
        targetPhase: PhaseID,
        settings: UserSettings,
        previousPeriods: [PhasePeriod]
    ) -> PhaseTransitionIntent {
        PhaseTransitionIntent(
            targetPhase: targetPhase,
            intendedToday: "2026-09-19",
            previousPeriods: previousPeriods,
            settings: settings
        )
    }

    private static func period(
        id: UUID = UUID(),
        phase: PhaseID,
        startedOn: String,
        endedOn: String? = nil
    ) -> PhasePeriod {
        PhasePeriod(id: id, phase: phase, startedOn: startedOn, endedOn: endedOn)
    }
}

/// The app's `PendingWrite` shape for the transition slice: the queue stays
/// generic, so the test payload mirrors exactly what `AppModel` persists.
private enum TestPhaseTransitionPayload: Codable, Equatable, Sendable {
    case phaseTransition(PhaseTransitionIntent)
}
