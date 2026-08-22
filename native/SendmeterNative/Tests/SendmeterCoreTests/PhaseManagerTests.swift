import XCTest
@testable import SendmeterCore

final class PhaseManagerTests: XCTestCase {
    func testSameDaySwitchBackReopensPreviousPeriod() {
        let current = PhasePeriod(
            id: UUID(),
            phase: .power,
            startedOn: "2026-08-15",
            endedOn: nil
        )
        let previous = PhasePeriod(
            id: UUID(),
            phase: .strength,
            startedOn: "2026-08-01",
            endedOn: "2026-08-15"
        )
        let plan = PhaseTransitionPlanner.plan(
            periods: [current, previous],
            newPhase: .strength,
            today: "2026-08-15"
        )
        XCTAssertEqual(
            plan.mutations,
            [
                .delete(periodID: current.id),
                .reopen(periodID: previous.id),
                .updateSettings(phase: .strength, startedOn: "2026-08-01")
            ]
        )
    }

    func testDifferentDayClosesAndCreates() {
        let current = PhasePeriod(
            id: UUID(),
            phase: .capacity,
            startedOn: "2026-08-01",
            endedOn: nil
        )
        let plan = PhaseTransitionPlanner.plan(
            periods: [current],
            newPhase: .strength,
            today: "2026-08-15"
        )
        XCTAssertEqual(
            plan.mutations,
            [
                .close(periodID: current.id, endedOn: "2026-08-15"),
                .create(phase: .strength, startedOn: "2026-08-15"),
                .updateSettings(phase: .strength, startedOn: "2026-08-15")
            ]
        )
    }

    func testSameDayChangeKeepsOpenPeriodStartedOn() {
        let current = PhasePeriod(
            id: UUID(),
            phase: .capacity,
            startedOn: "2026-08-15",
            endedOn: nil
        )
        // A same-day change to a different phase keeps the open period's
        // startedOn (no one-day sliver), so the block's start date is owned
        // by the period the user actually opened today (#545).
        let plan = PhaseTransitionPlanner.plan(
            periods: [current],
            newPhase: .strength,
            today: "2026-08-15"
        )
        XCTAssertEqual(
            plan.mutations,
            [
                .updatePhase(periodID: current.id, phase: .strength),
                .updateSettings(phase: .strength, startedOn: current.startedOn)
            ]
        )
    }
}
