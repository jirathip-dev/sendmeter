import XCTest
@testable import SendmeterCore

/// #919: the health-metric recovery POLICY. Health is the one direct-write
/// family where replaying a queued payload blindly is worse than dropping it,
/// so these tests pin the rules that make recovery safe:
///
/// * a queued score that is OLDER than the server's own row is never sent —
///   fresh data wins, and the queued score is retired as superseded;
/// * a write whose acknowledgement was lost is recognised from the server's
///   row instead of being repeated (including the `real`/float4 rounding the
///   biometric columns do on the way through Postgres);
/// * everything else is re-derived under the CURRENT write policy — the #109
///   readiness freeze and the #802 precedence split — against the server's
///   live row, with the intent's own trigger and today's date, so an intent
///   authored yesterday becomes a historical insert-if-missing rather than a
///   blind merge.
final class HealthWriteReplayTests: XCTestCase {
    private let timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    private let today = "2026-08-25"
    private let yesterday = "2026-08-24"
    private let accountUserID = UUID(uuidString: "91900000-0000-4000-8000-0000000000aa")!

    private func now(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    private func metric(
        date: String,
        readiness: Int? = 60,
        zone: String? = "maintain",
        computedAt: Date? = Date(timeIntervalSince1970: 1_000),
        hrv: Double? = 40,
        rhr: Double? = 55,
        sleep: Double? = 7
    ) -> HealthMetric {
        HealthMetric(
            date: date,
            readiness: readiness,
            zone: zone,
            computedAt: computedAt,
            hrvSDNNMilliseconds: hrv,
            restingHeartRate: rhr,
            sleepHours: sleep,
            sleepDeepHours: sleep.map { _ in 1 },
            sleepREMHours: sleep.map { _ in 1.5 },
            bodyMassKilograms: 65,
            respiratoryRate: 13
        )
    }

    private func intent(
        payload: HealthMetric,
        trigger: HealthWriteTrigger = .automatic,
        intendedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> HealthWriteIntent {
        HealthWriteIntent(
            date: payload.date,
            payload: payload,
            trigger: trigger,
            intendedAt: intendedAt
        )
    }

    // MARK: - Never landed

    func testMissingServerRowSendsTodayThroughTheMergeOperation() {
        let payload = metric(date: today)
        let decision = HealthWriteReplayPolicy.decide(
            intent: intent(payload: payload),
            serverRow: nil,
            now: now("2026-08-25T15:00:00Z"),
            timeZone: timeZone
        )

        XCTAssertEqual(decision, .send(payload: payload, operation: .todayMerge))
    }

    /// An intent authored while its date was "today" and replayed after
    /// midnight must NOT merge into the now-historical row: the operation is
    /// re-derived from the CURRENT day, and a historical write is the atomic
    /// insert-if-missing that cannot rewrite an existing row.
    func testIntentWhoseDateBecameHistoricalIsRederivedAsInsertIfMissing() {
        let payload = metric(date: yesterday)
        let decision = HealthWriteReplayPolicy.decide(
            intent: intent(payload: payload),
            serverRow: nil,
            now: now("2026-08-25T15:00:00Z"),
            timeZone: timeZone
        )

        XCTAssertEqual(decision, .send(payload: payload, operation: .historicalInsert))
    }

    func testExistingHistoricalRowIsNeverRewritten() {
        let payload = metric(date: yesterday, readiness: 40, computedAt: Date(timeIntervalSince1970: 1_000))
        let serverRow = metric(date: yesterday, readiness: 70, computedAt: Date(timeIntervalSince1970: 2_000))
        let decision = HealthWriteReplayPolicy.decide(
            intent: intent(payload: payload),
            serverRow: serverRow,
            now: now("2026-08-25T15:00:00Z"),
            timeZone: timeZone
        )

        XCTAssertEqual(decision, .superseded(serverRow: serverRow))
    }

    // MARK: - Lost acknowledgement

    func testLostAcknowledgementIsRecognisedFromTheServerRow() {
        let payload = metric(date: today)
        let decision = HealthWriteReplayPolicy.decide(
            intent: intent(payload: payload),
            serverRow: metric(date: today),
            now: now("2026-08-25T15:00:00Z"),
            timeZone: timeZone
        )

        XCTAssertEqual(decision, .alreadyApplied(serverRow: metric(date: today)))
    }

    /// The biometric columns are `real` (float4) in Postgres, so a row that
    /// round-tripped through the server differs from a Double payload in the
    /// low bits. Comparing at Double precision would make every lost
    /// acknowledgement look unsent and re-issue the write.
    func testLostAcknowledgementSurvivesTheFloat4RoundTrip() {
        let payload = metric(date: today, hrv: 40.123456789, rhr: 55.987654321)
        let serverRow = metric(
            date: today,
            hrv: Double(Float(40.123456789)),
            rhr: Double(Float(55.987654321))
        )
        XCTAssertNotEqual(payload.hrvSDNNMilliseconds, serverRow.hrvSDNNMilliseconds)

        let decision = HealthWriteReplayPolicy.decide(
            intent: intent(payload: payload),
            serverRow: serverRow,
            now: now("2026-08-25T15:00:00Z"),
            timeZone: timeZone
        )

        XCTAssertEqual(decision, .alreadyApplied(serverRow: serverRow))
    }

    /// The DB stamps `now()` when an insert carried no `computed_at`, so a
    /// keep-score / biometrics payload can come back with a different
    /// timestamp while being exactly the write that was sent.
    func testLostBiometricAcknowledgementIgnoresTheServerStampedTimestamp() {
        let payload = metric(date: today, readiness: nil, zone: nil, computedAt: nil)
        let serverRow = metric(
            date: today,
            readiness: 60,
            zone: "maintain",
            computedAt: Date(timeIntervalSince1970: 9_999),
            hrv: 40
        )
        let decision = HealthWriteReplayPolicy.decide(
            intent: intent(payload: payload),
            serverRow: serverRow,
            now: now("2026-08-25T15:00:00Z"),
            timeZone: timeZone
        )

        XCTAssertEqual(
            decision,
            .alreadyApplied(serverRow: serverRow),
            "the payload wrote only the biometrics, which the row now carries"
        )
    }

    func testLostAcknowledgementIsNotClaimedWhenAColumnStillDiffers() {
        let payload = metric(date: today, hrv: 40)
        let serverRow = metric(date: today, hrv: 41.5)
        let decision = HealthWriteReplayPolicy.decide(
            intent: intent(payload: payload),
            serverRow: serverRow,
            now: now("2026-08-25T15:00:00Z"),
            timeZone: timeZone
        )

        XCTAssertEqual(
            decision,
            .send(payload: payload.omittingReadiness(), operation: .todayMerge),
            "an unfinished write is completed, but the scored freeze still applies"
        )
    }

    // MARK: - Fresher server data wins (AC2)

    func testQueuedScoreOlderThanTheServerRowIsSupersededNotSent() {
        let payload = metric(
            date: today,
            readiness: 42,
            computedAt: Date(timeIntervalSince1970: 1_000)
        )
        let serverRow = metric(
            date: today,
            readiness: 71,
            computedAt: Date(timeIntervalSince1970: 2_000)
        )
        let decision = HealthWriteReplayPolicy.decide(
            intent: intent(payload: payload),
            serverRow: serverRow,
            now: now("2026-08-25T15:00:00Z"),
            timeZone: timeZone
        )

        XCTAssertEqual(
            decision,
            .superseded(serverRow: serverRow),
            "AC2: an old queued score must never overwrite the server's newer row"
        )
    }

    /// A queued score with no timestamp of its own cannot be proven older than
    /// a server row the server CAN date: never overwrite, and never guess.
    func testUndatableQueuedScoreNeverOverwritesADatedServerRow() {
        let payload = metric(date: today, readiness: 42, zone: "grow", computedAt: nil)
        let serverRow = metric(
            date: today,
            readiness: 71,
            computedAt: Date(timeIntervalSince1970: 2_000)
        )
        let decision = HealthWriteReplayPolicy.decide(
            intent: intent(payload: payload),
            serverRow: serverRow,
            now: now("2026-08-25T15:00:00Z"),
            timeZone: timeZone
        )

        XCTAssertEqual(decision, .superseded(serverRow: serverRow))
    }

    /// A row the watch left scoreless and empty of the phone's biometrics is
    /// not "already applied" just because the payload came from the same pass:
    /// the write is completed under the current policy.
    func testScorelessServerRowIsFilledByTheReDerivedWrite() {
        let stamp = Date(timeIntervalSince1970: 1_000)
        let payload = metric(date: today, computedAt: stamp, hrv: 40)
        let serverRow = metric(
            date: today,
            readiness: nil,
            zone: nil,
            computedAt: stamp,
            hrv: nil
        )
        let decision = HealthWriteReplayPolicy.decide(
            intent: intent(payload: payload),
            serverRow: serverRow,
            now: now("2026-08-25T15:00:00Z"),
            timeZone: timeZone
        )

        XCTAssertEqual(
            decision,
            .send(payload: payload, operation: .todayMerge),
            "the row carries no score to protect and no biometrics yet"
        )
    }

    // MARK: - #109 freeze and #802 precedence preserved (AC3)

    func testAutomaticAfternoonPassKeepsTheExistingScoreButStillSendsBiometrics() {
        let payload = metric(
            date: today,
            readiness: 38,
            zone: "caution",
            computedAt: Date(timeIntervalSince1970: 2_000),
            hrv: 44
        )
        let serverRow = metric(
            date: today,
            readiness: 66,
            computedAt: Date(timeIntervalSince1970: 1_000),
            hrv: 40
        )
        let decision = HealthWriteReplayPolicy.decide(
            intent: intent(payload: payload, trigger: .automatic),
            serverRow: serverRow,
            now: now("2026-08-25T15:00:00Z"),
            timeZone: timeZone
        )

        XCTAssertEqual(
            decision,
            .send(payload: payload.omittingReadiness(), operation: .todayMerge),
            "AC3: the #109 afternoon freeze keeps the scored reading"
        )
    }

    func testAutomaticMorningPassMayStillScore() {
        let payload = metric(
            date: today,
            readiness: 38,
            zone: "caution",
            computedAt: Date(timeIntervalSince1970: 2_000)
        )
        let serverRow = metric(
            date: today,
            readiness: 66,
            computedAt: Date(timeIntervalSince1970: 1_000)
        )
        let decision = HealthWriteReplayPolicy.decide(
            intent: intent(payload: payload, trigger: .automatic),
            serverRow: serverRow,
            now: now("2026-08-25T09:00:00Z"),
            timeZone: timeZone
        )

        XCTAssertEqual(decision, .send(payload: payload, operation: .todayMerge))
    }

    func testManualRecoveryIsAuthoritativeAndReplacesTheScore() {
        let payload = metric(
            date: today,
            readiness: 38,
            zone: "caution",
            computedAt: Date(timeIntervalSince1970: 2_000)
        )
        let serverRow = metric(
            date: today,
            readiness: 66,
            computedAt: Date(timeIntervalSince1970: 1_000)
        )
        let decision = HealthWriteReplayPolicy.decide(
            intent: intent(payload: payload, trigger: .manual),
            serverRow: serverRow,
            now: now("2026-08-25T15:00:00Z"),
            timeZone: timeZone
        )

        XCTAssertEqual(
            decision,
            .send(payload: payload, operation: .todayMerge),
            "#109: a manual sync bypasses the noon lock"
        )
    }

    func testFreezeResolvedWriteIsAppliedWhenOnlyTheScoreWasMissing() {
        let payload = metric(
            date: today,
            readiness: 38,
            zone: "caution",
            computedAt: Date(timeIntervalSince1970: 2_000),
            hrv: 44
        )
        let serverRow = metric(
            date: today,
            readiness: 66,
            computedAt: Date(timeIntervalSince1970: 1_000),
            hrv: 44
        )
        let decision = HealthWriteReplayPolicy.decide(
            intent: intent(payload: payload, trigger: .automatic),
            serverRow: serverRow,
            now: now("2026-08-25T15:00:00Z"),
            timeZone: timeZone
        )

        XCTAssertEqual(
            decision,
            .alreadyApplied(serverRow: serverRow),
            "the kept score plus the already-present biometrics are the whole write"
        )
    }

    // MARK: - Identity and durability

    func testQueueIdentityIsStableAndPerDateAndPerAccount() {
        let otherAccount = UUID(uuidString: "91900000-0000-4000-8000-0000000000bb")!
        let first = HealthWriteIdentity.queueItemID(
            for: today,
            accountUserID: accountUserID
        )
        XCTAssertEqual(
            first,
            HealthWriteIdentity.queueItemID(for: today, accountUserID: accountUserID)
        )
        XCTAssertEqual(
            first,
            HealthWriteIdentity.queueItemID(for: " \(today) ", accountUserID: accountUserID)
        )
        XCTAssertNotEqual(
            first,
            HealthWriteIdentity.queueItemID(for: yesterday, accountUserID: accountUserID)
        )
        XCTAssertEqual(
            intent(payload: metric(date: today)).queueIdentity(accountUserID: accountUserID),
            first,
            "the intent maps to the same key as the identity function"
        )

        // The scheduled date is the same for every account on the device, and
        // the queue is ONE shared file: an identity that did not include the
        // account would collide with another account's pending write for the
        // same day and could never be enqueued at all.
        let other = HealthWriteIdentity.queueItemID(
            for: today,
            accountUserID: otherAccount
        )
        XCTAssertNotEqual(other, first)
        XCTAssertNotEqual(
            HealthWriteIdentity.queueItemID(for: today, accountUserID: otherAccount),
            HealthWriteIdentity.queueItemID(for: today, accountUserID: UUID())
        )

        let queue = try? DurableQueue<HealthWriteIntent>(
            directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("health-write-identity-\(UUID().uuidString)"),
            filename: "pending.json"
        )
        XCTAssertNotNil(queue, "the existing durable queue carries the intent — no second queue engine")
    }

    func testIntentRoundTripsThroughTheDurableQueueEncoding() throws {
        let original = HealthWriteIntent(
            date: today,
            payload: metric(date: today, readiness: nil, zone: nil, computedAt: nil),
            trigger: .manual,
            operationID: UUID(uuidString: "91900000-0000-4000-8000-000000000001")!,
            intendedAt: Date(timeIntervalSince1970: 1_234)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(
            HealthWriteIntent.self,
            from: try encoder.encode(original)
        )

        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.trigger, .manual)
        XCTAssertEqual(
            restored.queueIdentity(accountUserID: accountUserID),
            original.queueIdentity(accountUserID: accountUserID)
        )
    }

    func testTriggerMappingPreservesTheWritePolicyInput() {
        XCTAssertEqual(HealthWriteTrigger(.manual).syncTrigger, .manual)
        XCTAssertEqual(HealthWriteTrigger(.automatic).syncTrigger, .automatic)
        XCTAssertEqual(HealthWriteTrigger(.automatic).rawValue, "automatic")
    }

    func testUnconfirmedWriteIsClassifiedRetryable() {
        XCTAssertEqual(HealthWriteReplayError.unconfirmedWrite.rejectionClass, .retryable)
    }
}
