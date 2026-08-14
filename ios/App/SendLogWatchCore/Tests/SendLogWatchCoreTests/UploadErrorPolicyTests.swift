import XCTest
import SendLogWatchCore

/// Issue #475: "non-retryable 4xx" was rejected as a class by both
/// reviewers — 401 needs a relay, 408/429 are transient, 403/409 are
/// ambiguous, and PostgREST surfaces DB errors by SQLSTATE rather than a
/// clean HTTP bucket. A later adversarial review (F5) additionally found
/// that matching the check-violation's constraint NAME as a string was
/// unsound (the table has two check constraints, not the one the comment
/// claimed) — these now pin the redesigned taxonomy: quarantine requires
/// SQLSTATE 23514 + stage `.climbAttempts` + the bundle itself still
/// carrying a non-positive-duration attempt, never a message-string match.
/// Issue #605 then re-classified 403: with the drain loop already matching
/// the item's owner to the stored account, a 403 is usually a verdict
/// about the credential, so it routes to `.needsAuthRelay` (bounded by
/// `QueueRetryPolicy.max403RelayPasses` — see `QueueRetryPolicyTests`
/// below for the permanent-403 answer); 409 stays `.retry`.
final class UploadErrorClassifierTests: XCTestCase {
    private func classify(
        httpStatus: Int? = nil,
        postgrestCode: String? = nil,
        message: String? = nil,
        stage: UploadStage? = .climbAttempts,
        hasNonPositiveDurationAttempt: Bool = false
    ) -> UploadErrorOutcome {
        UploadErrorClassifier.classify(
            UploadFailure(httpStatus: httpStatus, postgrestCode: postgrestCode, message: message),
            stage: stage,
            bundleHasNonPositiveDurationAttempt: hasNonPositiveDurationAttempt
        )
    }

    func test401NeedsAuthRelay() {
        XCTAssertEqual(classify(httpStatus: 401), .needsAuthRelay)
    }

    /// #475 F2: a real 401 from this project's production PostgREST never
    /// arrives as an `HTTPError` with `httpStatus == 401` — PostgREST
    /// decodes a body-carrying failure as `PostgrestError` first, and a bad
    /// bearer token's body decodes cleanly. Observed response, verbatim:
    /// `{"code":"PGRST301","details":"None of the keys was able to decode
    /// the JWT","hint":null,"message":"No suitable key or wrong key type"}`.
    /// `httpStatus` is deliberately nil here — that field never gets
    /// populated for this case in production.
    func testPGRST301FromARealResponseBodyNeedsAuthRelay() {
        XCTAssertEqual(
            classify(postgrestCode: "PGRST301", message: "No suitable key or wrong key type"),
            .needsAuthRelay
        )
    }

    func testPGRST302AlsoNeedsAuthRelay() {
        XCTAssertEqual(classify(postgrestCode: "PGRST302", message: "JWT expired"), .needsAuthRelay)
    }

    func test408And429AreRetryableNotPermanent() {
        XCTAssertEqual(classify(httpStatus: 408), .retry)
        XCTAssertEqual(classify(httpStatus: 429), .retry)
    }

    /// #605: a 403 is usually a verdict about the credential, not the
    /// bundle — `shouldDrain` has already matched the item's owner to the
    /// stored account by the time a 403 can happen, so the remaining ways
    /// to earn one are credential-side (stale relay, `WatchSessionStore`'s
    /// `userId` drifting from the bearer token, …). It routes to
    /// `.needsAuthRelay` so the drain loop requests a fresh relay instead
    /// of spending the item's F3 budget on it.
    func test403NeedsAuthRelay() {
        XCTAssertEqual(classify(httpStatus: 403), .needsAuthRelay)
    }

    func test409RemainsAmbiguousSoItRetries() {
        // 409 can be an ordering conflict rather than poison — and unlike
        // 403 it is not credential-side, so it stays on the ordinary
        // `.retry` path.
        XCTAssertEqual(classify(httpStatus: 409), .retry)
    }

    func test5xxIsRetryable() {
        XCTAssertEqual(classify(httpStatus: 500), .retry)
        XCTAssertEqual(classify(httpStatus: 503), .retry)
    }

    /// The exact scenario this classifier exists to catch: a check
    /// violation, on the attempts upsert, of a bundle that still carries a
    /// non-positive-duration attempt (only possible on a pre-#475 build).
    func testCheckViolationOnClimbAttemptsWithAPoisonedAttemptQuarantines() {
        XCTAssertEqual(
            classify(
                postgrestCode: "23514",
                message: "new row for relation \"climb_attempts\" violates check constraint \"climb_attempts_duration_s_check\"",
                stage: .climbAttempts,
                hasNonPositiveDurationAttempt: true
            ),
            .quarantine
        )
    }

    /// #475 F5: quarantine must NOT fire on message content alone — even a
    /// message naming the exact duration constraint must not quarantine a
    /// bundle that doesn't actually have the poisoned shape (e.g. a stale
    /// error body, or a message-matching heuristic resurrected by a future
    /// edit). The bundle-evidence check is what makes this exact.
    func testMatchingMessageAloneWithoutPoisonedBundleContentDoesNotQuarantine() {
        XCTAssertEqual(
            classify(
                postgrestCode: "23514",
                message: "new row for relation \"climb_attempts\" violates check constraint \"climb_attempts_duration_s_check\"",
                stage: .climbAttempts,
                hasNonPositiveDurationAttempt: false
            ),
            .retry
        )
    }

    /// The OTHER check constraint on the same table
    /// (`climb_attempts_source_check`, #475 F5) must not quarantine either:
    /// same SQLSTATE, same stage, but the bundle has no non-positive
    /// duration attempt.
    func testADifferentCheckConstraintOnTheSameTableDoesNotQuarantine() {
        XCTAssertEqual(
            classify(
                postgrestCode: "23514",
                message: "new row for relation \"climb_attempts\" violates check constraint \"climb_attempts_source_check\"",
                stage: .climbAttempts,
                hasNonPositiveDurationAttempt: false
            ),
            .retry
        )
    }

    /// A check violation on a DIFFERENT table's upsert (#475 F3's own
    /// example: `climb_workouts_check`, `ended_at >= started_at`) must not
    /// quarantine even if the bundle happens to also carry a bad-duration
    /// attempt — the failing stage says the rejection wasn't about attempts
    /// at all.
    func testCheckViolationOnADifferentStageDoesNotQuarantine() {
        XCTAssertEqual(
            classify(
                postgrestCode: "23514",
                message: "new row for relation \"climb_workouts\" violates check constraint \"climb_workouts_check\"",
                stage: .climbWorkout,
                hasNonPositiveDurationAttempt: true
            ),
            .retry
        )
    }

    func testUnknownStageDoesNotQuarantine() {
        XCTAssertEqual(
            classify(
                postgrestCode: "23514",
                stage: nil,
                hasNonPositiveDurationAttempt: true
            ),
            .retry
        )
    }

    func testUniqueViolationDoesNotQuarantine() {
        XCTAssertEqual(
            classify(
                httpStatus: 409,
                postgrestCode: "23505",
                message: "duplicate key value violates unique constraint \"climb_attempts_pkey\"",
                hasNonPositiveDurationAttempt: true
            ),
            .retry
        )
    }

    func testAnUnrecognizedFailureDefaultsToRetryNeverQuarantine() {
        // A network error, a decode failure, or anything else this
        // classifier doesn't specifically know about — the conservative
        // default is retry, not quarantine.
        XCTAssertEqual(classify(), .retry)
    }
}

/// #475 F3: every permanent error that ISN'T the one named constraint
/// still parks the queue forever without a bound. These pin the pure
/// decision `OfflineQueue`'s retry ledger consumes.
final class QueueRetryPolicyTests: XCTestCase {
    func testStaysRetryLaterBelowTheThreshold() {
        let decision = QueueRetryPolicy.afterFailedAttempt(previousConsecutiveFailures: 0)
        XCTAssertEqual(decision, .retryLater(consecutiveFailures: 1))
    }

    func testJustBelowThresholdIsStillRetryLater() {
        let decision = QueueRetryPolicy.afterFailedAttempt(
            previousConsecutiveFailures: QueueRetryPolicy.maxConsecutiveFailures - 2
        )
        XCTAssertEqual(
            decision,
            .retryLater(consecutiveFailures: QueueRetryPolicy.maxConsecutiveFailures - 1)
        )
    }

    func testReachingTheThresholdBecomesStuck() {
        let decision = QueueRetryPolicy.afterFailedAttempt(
            previousConsecutiveFailures: QueueRetryPolicy.maxConsecutiveFailures - 1
        )
        XCTAssertEqual(
            decision,
            .stuck(consecutiveFailures: QueueRetryPolicy.maxConsecutiveFailures)
        )
    }

    func testWellPastTheThresholdStaysStuck() {
        let decision = QueueRetryPolicy.afterFailedAttempt(
            previousConsecutiveFailures: QueueRetryPolicy.maxConsecutiveFailures + 50
        )
        if case .stuck = decision {} else { XCTFail("expected .stuck, got \(decision)") }
    }

    // MARK: #605 — the 403 stale-auth relay budget

    /// The first 403 pass on an item is treated as stale auth — it gets a
    /// fresh-relay ask, not a ledger count.
    func testTheFirst403PassIsTreatedAsStaleAuth() {
        XCTAssertTrue(QueueRetryPolicy.shouldTreat403AsStaleAuth(consecutive403Passes: 1))
    }

    /// The budgeted number of passes is still stale-auth: the full budget
    /// is spendable before any 403 counts as a verdict.
    func testTheBudgetedNumberOf403PassesIsStillStaleAuth() {
        XCTAssertTrue(QueueRetryPolicy.shouldTreat403AsStaleAuth(
            consecutive403Passes: QueueRetryPolicy.max403RelayPasses
        ))
    }

    /// Past the budget, a 403 is no longer the auth explanation — it is a
    /// genuine server verdict and must count toward the F3 ledger.
    func testAPassBeyondTheRelayBudgetIsNoLongerStaleAuth() {
        XCTAssertFalse(QueueRetryPolicy.shouldTreat403AsStaleAuth(
            consecutive403Passes: QueueRetryPolicy.max403RelayPasses + 1
        ))
    }

    /// The permanent-403 bound, stated as a guarantee: simulate a
    /// permanent-403 item through the whole decision pipeline — the first
    /// `max403RelayPasses` passes are stale-auth (relay ask, no count);
    /// every pass after that counts toward the F3 ledger, and the
    /// `maxConsecutiveFailures`-th counted pass is the `.stuck` one. So a
    /// truly permanent 403 can never stall the queue forever: it is
    /// quarantined `.stuckRetrying` after at most
    /// `max403RelayPasses + maxConsecutiveFailures` rejected passes — the
    /// #475 F3 backstop reached later for 403, never weakened.
    func testAPermanent403QuarantinesWithinTheCombinedBound() {
        var counted = 0
        var staleAuthPasses = 0
        var stuckAtTotalPass = -1
        for pass in 1...(QueueRetryPolicy.max403RelayPasses + QueueRetryPolicy.maxConsecutiveFailures) {
            if QueueRetryPolicy.shouldTreat403AsStaleAuth(consecutive403Passes: pass) {
                staleAuthPasses += 1
            } else {
                if case .stuck = QueueRetryPolicy.afterFailedAttempt(previousConsecutiveFailures: counted) {
                    stuckAtTotalPass = pass
                    break
                }
                counted += 1
            }
        }
        XCTAssertEqual(staleAuthPasses, QueueRetryPolicy.max403RelayPasses)
        XCTAssertEqual(counted, QueueRetryPolicy.maxConsecutiveFailures - 1)
        XCTAssertEqual(stuckAtTotalPass, QueueRetryPolicy.max403RelayPasses + QueueRetryPolicy.maxConsecutiveFailures)
    }

    // MARK: #475 F12 — the stuck-retrying backoff

    func testJustBelowTheBackoffIsNotDueYet() {
        let quarantinedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let now = quarantinedAt.addingTimeInterval(QueueRetryPolicy.stuckRetryBackoffS - 1)
        XCTAssertFalse(QueueRetryPolicy.isStuckRetryDue(quarantinedAt: quarantinedAt, now: now))
    }

    func testExactlyAtTheBackoffIsDue() {
        let quarantinedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let now = quarantinedAt.addingTimeInterval(QueueRetryPolicy.stuckRetryBackoffS)
        XCTAssertTrue(QueueRetryPolicy.isStuckRetryDue(quarantinedAt: quarantinedAt, now: now))
    }

    func testWellPastTheBackoffIsDue() {
        let quarantinedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let now = quarantinedAt.addingTimeInterval(QueueRetryPolicy.stuckRetryBackoffS * 3)
        XCTAssertTrue(QueueRetryPolicy.isStuckRetryDue(quarantinedAt: quarantinedAt, now: now))
    }
}
