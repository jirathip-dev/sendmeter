import XCTest
@testable import SendmeterCore

final class HealthMetricReconciliationTests: XCTestCase {
    private let today = "2026-08-25"
    private let yesterday = "2026-08-24"
    private let older = "2026-08-10"
    private let timeZone = TimeZone(secondsFromGMT: 0) ?? .current

    private func metric(
        date: String,
        readiness: Int? = 60,
        computedAt: Date? = Date(timeIntervalSince1970: 1_000),
        hrv: Double? = 40,
        rhr: Double? = 55,
        sleep: Double? = 7,
        bodyMass: Double? = 65,
        respiratoryRate: Double? = 13
    ) -> HealthMetric {
        HealthMetric(
            date: date,
            readiness: readiness,
            zone: readiness == nil ? nil : "maintain",
            computedAt: computedAt,
            hrvSDNNMilliseconds: hrv,
            restingHeartRate: rhr,
            sleepHours: sleep,
            sleepDeepHours: sleep.map { _ in 1 },
            sleepREMHours: sleep.map { _ in 1.5 },
            bodyMassKilograms: bodyMass,
            respiratoryRate: respiratoryRate
        )
    }

    func testMissedHistoricalDayIsBackfilled() {
        let plan = HealthMetricReconciliationPolicy.plan(
            freshMetrics: [metric(date: yesterday)],
            existingMetrics: [],
            today: today,
            allowTodayReadinessOverwrite: true,
            timeZone: timeZone
        )

        XCTAssertEqual(plan.upserts.map(\.date), [yesterday])
        XCTAssertEqual(plan.reconciledDates, [yesterday])
        XCTAssertEqual(plan.sourceDataDates, [yesterday])
    }

    func testReadWindowUsesExactly28CandidatesAnd55DayQueryBoundary() {
        XCTAssertEqual(HealthMetricReadWindow.candidateDays, 28)
        XCTAssertEqual(HealthMetricReadWindow.baselineDays, 28)
        XCTAssertEqual(HealthMetricReadWindow.queryLookbackDays, 55)
        XCTAssertEqual(HealthMetricReadWindow.candidateOffsets.count, 28)
        XCTAssertEqual(HealthMetricReadWindow.candidateOffsets.first, 0)
        XCTAssertEqual(HealthMetricReadWindow.candidateOffsets.last, 27)
        XCTAssertEqual(HealthMetricReadWindow.baselineOffsets.count, 28)
        XCTAssertEqual(HealthMetricReadWindow.baselineOffsets.first, 1)
        XCTAssertEqual(HealthMetricReadWindow.baselineOffsets.last, 28)

        let newestHistorical = metric(date: "2026-07-29") // today - 27
        let outsideCandidateWindow = metric(date: "2026-07-28") // today - 28
        let plan = HealthMetricReconciliationPolicy.plan(
            freshMetrics: [newestHistorical, outsideCandidateWindow],
            existingMetrics: [],
            today: today,
            allowTodayReadinessOverwrite: true,
            timeZone: timeZone
        )

        XCTAssertEqual(plan.sourceDataDates, ["2026-07-29"])
        XCTAssertEqual(plan.upserts.map(\.date), ["2026-07-29"])
    }

    func testNoDataCandidateIsOmitted() {
        let empty = metric(
            date: yesterday,
            readiness: 0,
            hrv: nil,
            rhr: nil,
            sleep: nil,
            bodyMass: nil,
            respiratoryRate: nil
        )
        let plan = HealthMetricReconciliationPolicy.plan(
            freshMetrics: [empty],
            existingMetrics: [],
            today: today,
            allowTodayReadinessOverwrite: true,
            timeZone: timeZone
        )

        XCTAssertTrue(plan.upserts.isEmpty)
        XCTAssertTrue(plan.sourceDataDates.isEmpty)
        XCTAssertNil(plan.relayMetric)
    }

    func testPersistedHistoricalDayIsUntouched() {
        let existing = metric(date: yesterday, readiness: 72, hrv: 35)
        let newerHealthKitRead = metric(
            date: yesterday,
            readiness: 55,
            computedAt: Date(timeIntervalSince1970: 2_000),
            hrv: 48
        )
        let plan = HealthMetricReconciliationPolicy.plan(
            freshMetrics: [newerHealthKitRead],
            existingMetrics: [existing],
            today: today,
            allowTodayReadinessOverwrite: true,
            timeZone: timeZone
        )

        XCTAssertTrue(plan.upserts.isEmpty)
        XCTAssertTrue(plan.reconciledDates.isEmpty)
        XCTAssertEqual(plan.sourceDataDates, [yesterday])
    }

    func testTodayUsesTheExistingFreezePolicyButStillUpdatesBiometrics() {
        let existing = metric(date: today, readiness: 74, hrv: 40)
        let fresh = metric(
            date: today,
            readiness: 58,
            computedAt: Date(timeIntervalSince1970: 2_000),
            hrv: 41
        )
        let locked = HealthMetricReconciliationPolicy.plan(
            freshMetrics: [fresh],
            existingMetrics: [existing],
            today: today,
            allowTodayReadinessOverwrite: false,
            timeZone: timeZone
        )

        XCTAssertEqual(locked.relayMetric, existing)
        XCTAssertEqual(locked.upserts.count, 1)
        XCTAssertNil(locked.upserts[0].readiness)
        XCTAssertNil(locked.upserts[0].computedAt)
        XCTAssertEqual(locked.upserts[0].hrvSDNNMilliseconds, 41)

        let allowed = HealthMetricReconciliationPolicy.plan(
            freshMetrics: [fresh],
            existingMetrics: [existing],
            today: today,
            allowTodayReadinessOverwrite: true,
            timeZone: timeZone
        )
        XCTAssertEqual(allowed.relayMetric, fresh)
        XCTAssertEqual(allowed.upserts, [fresh])
    }

    func testRepeatedSyncWithNoNewDataIsIdempotent() {
        let firstRead = [
            metric(date: today, readiness: 62),
            metric(date: older, readiness: nil, hrv: 42),
        ]
        let first = HealthMetricReconciliationPolicy.plan(
            freshMetrics: firstRead,
            existingMetrics: [],
            today: today,
            allowTodayReadinessOverwrite: true,
            timeZone: timeZone
        )
        XCTAssertEqual(first.upserts.count, 2)

        let secondRead = [
            metric(date: today, readiness: 62, computedAt: Date(timeIntervalSince1970: 9_000)),
            metric(date: older, readiness: nil, computedAt: Date(timeIntervalSince1970: 9_000), hrv: 42),
        ]
        let second = HealthMetricReconciliationPolicy.plan(
            freshMetrics: secondRead,
            existingMetrics: first.upserts,
            today: today,
            allowTodayReadinessOverwrite: true,
            timeZone: timeZone
        )

        XCTAssertTrue(second.upserts.isEmpty)
        XCTAssertEqual(second.reconciledCount, 0)
        XCTAssertEqual(second.sourceDataDates, [today, older])
    }

    func testMorningRepollTimingAndDedupe() {
        let policy = HealthMorningRefreshPolicy()
        let calendar = LocalDateSupport.calendar(timeZone: timeZone)
        guard let morning = calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: 2026,
            month: 8,
            day: 25,
            hour: 7
        )), let afternoon = calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: 2026,
            month: 8,
            day: 25,
            hour: 14
        )) else {
            XCTFail("fixed test dates should be constructible")
            return
        }

        XCTAssertEqual(policy.delay(forPass: 0), 0)
        XCTAssertEqual(policy.delay(forPass: 1), 5 * 60)
        XCTAssertEqual(policy.delay(forPass: 2), 15 * 60)
        XCTAssertEqual(policy.interval(fromPass: 0, toPass: 1), 5 * 60)
        XCTAssertEqual(policy.interval(fromPass: 1, toPass: 2), 10 * 60)
        XCTAssertTrue(policy.shouldStart(at: morning, lastStartedAt: nil, calendar: calendar))
        XCTAssertFalse(policy.shouldStart(at: morning, lastStartedAt: morning, calendar: calendar))
        XCTAssertFalse(policy.shouldStart(at: afternoon, lastStartedAt: nil, calendar: calendar))

        var progress = HealthMorningRefreshProgress(
            accountUserID: UUID(),
            startedAt: morning
        )
        XCTAssertEqual(policy.duePass(for: progress, at: morning), 0)
        progress.nextPass = 1
        XCTAssertNil(
            policy.duePass(
                for: progress,
                at: morning.addingTimeInterval(5 * 60 - 1)
            )
        )
        XCTAssertEqual(
            policy.duePass(
                for: progress,
                at: morning.addingTimeInterval(5 * 60)
            ),
            1
        )
        progress.add(.reconciled(1))
        progress.nextPass = 2
        XCTAssertEqual(
            policy.duePass(
                for: progress,
                at: morning.addingTimeInterval(15 * 60)
            ),
            2
        )

        var gate = HealthRepollGate()
        XCTAssertTrue(gate.claim())
        XCTAssertFalse(gate.claim())
        gate.release()
        XCTAssertTrue(gate.claim(), "cancellation/release permits a fresh account-scoped window")
    }

    func testHistoricalWritesIgnoreConflictsAndTodayMerges() {
        XCTAssertEqual(
            HealthMetricWritePolicy.operation(for: yesterday, today: today),
            .historicalInsert
        )
        XCTAssertEqual(
            HealthMetricWriteOperation.historicalInsert.preferHeader,
            "resolution=ignore-duplicates,return=representation"
        )
        XCTAssertEqual(
            HealthMetricWritePolicy.operation(for: today, today: today),
            .todayMerge
        )
        XCTAssertEqual(
            HealthMetricWriteOperation.todayMerge.preferHeader,
            "resolution=merge-duplicates,return=minimal"
        )
    }

    func testCancellationAndAccountChangeCannotPublishOldWork() {
        let userA = UUID()
        let userB = UUID()
        let captured = AccountScopedFetch(accountUserID: userA, accountEpoch: 4)

        XCTAssertTrue(captured.canApply(to: userA, accountEpoch: 4))
        XCTAssertFalse(captured.canApply(to: userB, accountEpoch: 4))
        XCTAssertFalse(captured.canApply(to: userA, accountEpoch: 5))

        var gate = ReadinessRecomputeGate()
        XCTAssertEqual(gate.request(), .start)
        XCTAssertEqual(gate.request(), .queued)
        gate.cancel()
        XCTAssertFalse(gate.isRunning)
        XCTAssertEqual(gate.request(), .start)
    }

    func testObservableSuccessOnlyAnnouncesARealReconciliation() {
        let changed = HealthSyncObservation.successful(
            reconciledCount: 2,
            sourceDataCount: 3
        )
        XCTAssertEqual(changed, .reconciled(2))
        XCTAssertEqual(changed.automaticConfirmationMessage, "Apple Health updated · 2 days")

        let noChange = HealthSyncObservation.successful(
            reconciledCount: 0,
            sourceDataCount: 3
        )
        XCTAssertEqual(noChange, .noNewData)
        XCTAssertNil(noChange.automaticConfirmationMessage)

        let noSource = HealthSyncObservation.successful(
            reconciledCount: 0,
            sourceDataCount: 0
        )
        XCTAssertEqual(noSource, .noSourceData)
        XCTAssertNil(noSource.automaticConfirmationMessage)
        XCTAssertNil(HealthSyncObservation.failed.automaticConfirmationMessage)
    }
}
