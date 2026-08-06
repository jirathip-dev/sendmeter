import XCTest
import SendLogWatchCore

/// Issue #475: "non-retryable 4xx" was rejected as a class by both
/// reviewers — 401 needs a relay, 408/429 are transient, 403/409 are
/// ambiguous, and PostgREST surfaces DB errors by SQLSTATE rather than a
/// clean HTTP bucket. These pin the taxonomy: quarantine keys ONLY on the
/// specific `climb_attempts_duration_s_check` violation, and everything
/// else — including every other 4xx and every other check constraint —
/// defaults to retry.
final class UploadErrorClassifierTests: XCTestCase {
    func test401NeedsAuthRelay() {
        XCTAssertEqual(
            UploadErrorClassifier.classify(UploadFailure(httpStatus: 401)),
            .needsAuthRelay
        )
    }

    func test408And429AreRetryableNotPermanent() {
        XCTAssertEqual(UploadErrorClassifier.classify(UploadFailure(httpStatus: 408)), .retry)
        XCTAssertEqual(UploadErrorClassifier.classify(UploadFailure(httpStatus: 429)), .retry)
    }

    func test403And409AreAmbiguousSoTheyRetry() {
        // 403 can be stale auth or a real RLS denial; 409 can be an
        // ordering conflict rather than poison. Neither is safe to
        // quarantine on status code alone.
        XCTAssertEqual(UploadErrorClassifier.classify(UploadFailure(httpStatus: 403)), .retry)
        XCTAssertEqual(UploadErrorClassifier.classify(UploadFailure(httpStatus: 409)), .retry)
    }

    func test5xxIsRetryable() {
        XCTAssertEqual(UploadErrorClassifier.classify(UploadFailure(httpStatus: 500)), .retry)
        XCTAssertEqual(UploadErrorClassifier.classify(UploadFailure(httpStatus: 503)), .retry)
    }

    func testTheNamedDurationCheckViolationQuarantines() {
        let failure = UploadFailure(
            httpStatus: 400,
            postgrestCode: "23514",
            message: "new row for relation \"climb_attempts\" violates check constraint \"climb_attempts_duration_s_check\""
        )
        XCTAssertEqual(UploadErrorClassifier.classify(failure), .quarantine)
    }

    func testADifferentCheckConstraintOnTheSameSQLStateDoesNotQuarantine() {
        // Same SQLSTATE class, different table/column — quarantine must key
        // on the specific named constraint, not "any 23514".
        let failure = UploadFailure(
            httpStatus: 400,
            postgrestCode: "23514",
            message: "new row for relation \"climb_workouts\" violates check constraint \"climb_workouts_check\""
        )
        XCTAssertEqual(UploadErrorClassifier.classify(failure), .retry)
    }

    func testACheckViolationWithNoMessageDoesNotQuarantine() {
        // Defensive: the constraint-name match is the only signal: without
        // a message to search, default to the safe side.
        let failure = UploadFailure(httpStatus: 400, postgrestCode: "23514", message: nil)
        XCTAssertEqual(UploadErrorClassifier.classify(failure), .retry)
    }

    func testUniqueViolationDoesNotQuarantine() {
        let failure = UploadFailure(
            httpStatus: 409,
            postgrestCode: "23505",
            message: "duplicate key value violates unique constraint \"climb_attempts_pkey\""
        )
        XCTAssertEqual(UploadErrorClassifier.classify(failure), .retry)
    }

    func testAnUnrecognizedFailureDefaultsToRetryNeverQuarantine() {
        // A network error, a decode failure, or anything else this
        // classifier doesn't specifically know about — the conservative
        // default is retry, not quarantine.
        XCTAssertEqual(UploadErrorClassifier.classify(UploadFailure()), .retry)
    }
}
