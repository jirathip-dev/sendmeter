import XCTest
@testable import SendmeterCore

final class ReadinessSyncPolicyTests: XCTestCase {
    private let today = "2026-08-17"

    private func metric(
        date: String? = nil,
        readiness: Int?,
        computedAt: Date? = Date(timeIntervalSince1970: 1000)
    ) -> HealthMetric {
        HealthMetric(
            date: date ?? today,
            readiness: readiness,
            zone: readiness.map { _ in "maintain" },
            computedAt: computedAt,
            hrvSDNNMilliseconds: 40,
            restingHeartRate: 55,
            sleepHours: 7,
            sleepDeepHours: 1,
            sleepREMHours: 1.5,
            bodyMassKilograms: 65,
            respiratoryRate: 13
        )
    }

    func testFreshScoreWinsWhenAllowed() {
        let existing = metric(readiness: 74, computedAt: Date(timeIntervalSince1970: 500))
        let fresh = metric(readiness: 62, computedAt: Date(timeIntervalSince1970: 2000))
        let plan = ReadinessSyncPolicy.plan(
            existingToday: existing,
            freshlyComputed: fresh,
            allowReadinessOverwrite: true
        )
        XCTAssertEqual(plan.relayMetric, fresh)
        XCTAssertEqual(plan.upsertMetric, fresh)
    }

    func testNilFreshScoreKeepsExistingScoredReading() {
        let existing = metric(readiness: 74, computedAt: Date(timeIntervalSince1970: 500))
        let fresh = metric(readiness: nil, computedAt: Date(timeIntervalSince1970: 2000))
        let plan = ReadinessSyncPolicy.plan(
            existingToday: existing,
            freshlyComputed: fresh,
            allowReadinessOverwrite: true
        )
        // AC2: a silent/foreground refresh must never blank a scored reading.
        XCTAssertEqual(plan.relayMetric, existing)
        // The upsert keeps only the fresh biometrics — readiness/zone/computedAt
        // nil so the DB row's score + computed_at survive.
        XCTAssertNil(plan.upsertMetric.readiness)
        XCTAssertNil(plan.upsertMetric.zone)
        XCTAssertNil(plan.upsertMetric.computedAt)
        XCTAssertEqual(plan.upsertMetric.hrvSDNNMilliseconds, fresh.hrvSDNNMilliseconds)
    }

    func testLockedPassKeepsExistingScoredReadingEvenWithFreshScore() {
        // #109: after noon an automatic sync does not overwrite today's score.
        let existing = metric(readiness: 71, computedAt: Date(timeIntervalSince1970: 500))
        let fresh = metric(readiness: 58, computedAt: Date(timeIntervalSince1970: 2000))
        let plan = ReadinessSyncPolicy.plan(
            existingToday: existing,
            freshlyComputed: fresh,
            allowReadinessOverwrite: false
        )
        XCTAssertEqual(plan.relayMetric, existing)
        XCTAssertNil(plan.upsertMetric.readiness)
        XCTAssertNil(plan.upsertMetric.computedAt)
    }

    func testNoExistingScoredReadingRelaysHonestEmpty() {
        // A genuinely empty read with no prior score stays honest (nil),
        // never fabricated.
        let fresh = metric(readiness: nil, computedAt: nil)
        let plan = ReadinessSyncPolicy.plan(
            existingToday: nil,
            freshlyComputed: fresh,
            allowReadinessOverwrite: true
        )
        XCTAssertNil(plan.relayMetric.readiness)
        XCTAssertNil(plan.upsertMetric.readiness)
        XCTAssertNil(plan.upsertMetric.computedAt)
    }

    func testNoExistingRowButFreshScoreWritesIt() {
        let fresh = metric(readiness: 60)
        let plan = ReadinessSyncPolicy.plan(
            existingToday: nil,
            freshlyComputed: fresh,
            allowReadinessOverwrite: true
        )
        XCTAssertEqual(plan.relayMetric, fresh)
        XCTAssertEqual(plan.upsertMetric, fresh)
    }

    func testExistingTodayRowForAnotherDateIsNotKept() {
        // The self-defense: only a today row is kept; an existing row for a
        // different date must not be preserved as if it were today's.
        let existing = metric(date: "2026-08-16", readiness: 74)
        let fresh = metric(readiness: nil)
        let plan = ReadinessSyncPolicy.plan(
            existingToday: existing,
            freshlyComputed: fresh,
            allowReadinessOverwrite: true
        )
        XCTAssertNil(plan.relayMetric.readiness)
    }
}
