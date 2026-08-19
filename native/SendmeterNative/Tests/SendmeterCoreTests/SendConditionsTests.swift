import XCTest
@testable import SendmeterCore

/// Mirrors `src/lib/weather.ts` thresholds EXACTLY — these tests pin the
/// native scoring to the web's formulas and label bands so the two surfaces
/// can never disagree about a reading.
final class SendConditionsTests: XCTestCase {
    // MARK: Sub-scores

    func testTempFrictionScorePeaksAtSixDegrees() {
        XCTAssertEqual(SendConditionsScore.tempFrictionScore(tempC: 6), 100, accuracy: 0.0001)
        XCTAssertEqual(SendConditionsScore.tempFrictionScore(tempC: 7), 94, accuracy: 0.0001)
        XCTAssertEqual(SendConditionsScore.tempFrictionScore(tempC: 16), 40, accuracy: 0.0001)
        XCTAssertEqual(SendConditionsScore.tempFrictionScore(tempC: 50), 0)
        XCTAssertEqual(SendConditionsScore.tempFrictionScore(tempC: -30), 0)
        // Clamps, never negative
        XCTAssertEqual(SendConditionsScore.tempFrictionScore(tempC: -10), 4, accuracy: 0.0001)
    }

    func testHumidityFrictionScoreDrierIsBetter() {
        XCTAssertEqual(SendConditionsScore.humidityFrictionScore(humidity: 0), 100, accuracy: 0.0001)
        XCTAssertEqual(SendConditionsScore.humidityFrictionScore(humidity: 50), 45, accuracy: 0.0001)
        // ~90.9% → 0, and anything above clamps to 0
        XCTAssertEqual(SendConditionsScore.humidityFrictionScore(humidity: 95), 0)
        XCTAssertEqual(SendConditionsScore.humidityFrictionScore(humidity: 100), 0)
    }

    // MARK: Overall score

    func testComputeSendScoreBlendsSixtyForty() {
        // Perfect conditions: 6°C / 0% → 100
        XCTAssertEqual(SendConditionsScore.computeSendScore(tempC: 6, humidity: 0), 100)
        // Web's documented hot-climate example (35°C / 45%): temp sub-score 0,
        // humidity 50.5 → round(0.4 × 50.5) = 20.
        XCTAssertEqual(SendConditionsScore.computeSendScore(tempC: 35, humidity: 45), 20)
        // Web's `prime` fixture: 5°C / 30% → 0.6×94 + 0.4×67 = 83.2 → 83
        XCTAssertEqual(SendConditionsScore.computeSendScore(tempC: 5, humidity: 30), 83)
        // Rounding is half-up: 0.6×94 + 0.4×100 = 96.4 → 96
        XCTAssertEqual(SendConditionsScore.computeSendScore(tempC: 5, humidity: 0), 96)
    }

    func testCurrentReadingSurvivesUnavailableArchiveContext() {
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let conditions = SendConditionsScore.makeConditions(
            tempC: 35,
            humidity: 45,
            hourOfDay: 14,
            climate: nil,
            fetchedAt: fetchedAt
        )

        XCTAssertEqual(conditions.score, 20)
        XCTAssertEqual(conditions.label, .poor)
        XCTAssertNil(conditions.percentile)
        XCTAssertNil(conditions.daysBelow)
        XCTAssertNil(conditions.daysTotal)
        XCTAssertNil(conditions.hist)
        XCTAssertEqual(conditions.fetchedAt, fetchedAt)
    }

    // MARK: Refresh freshness

    func testAutomaticWeatherRefreshUsesThirtyMinuteFreshnessWindow() {
        let policy = WeatherRefreshPolicy()
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertFalse(policy.shouldRefresh(
            trigger: .appear,
            lastFetchedAt: fetchedAt,
            now: fetchedAt.addingTimeInterval(WeatherRefreshPolicy.defaultFreshnessWindow - 1)
        ))
        XCTAssertFalse(policy.shouldRefresh(
            trigger: .foreground,
            lastFetchedAt: fetchedAt,
            now: fetchedAt.addingTimeInterval(WeatherRefreshPolicy.defaultFreshnessWindow)
        ))
        XCTAssertTrue(policy.shouldRefresh(
            trigger: .appear,
            lastFetchedAt: fetchedAt,
            now: fetchedAt.addingTimeInterval(WeatherRefreshPolicy.defaultFreshnessWindow + 1)
        ))
    }

    func testManualWeatherRefreshBypassesFreshnessWindow() {
        let policy = WeatherRefreshPolicy()
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertTrue(policy.shouldRefresh(
            trigger: .manual,
            lastFetchedAt: fetchedAt,
            now: fetchedAt.addingTimeInterval(1)
        ))
    }

    func testScoreLabelBandsMatchWeb() {
        XCTAssertEqual(SendConditionsScore.scoreLabel(score: 75), .prime)
        XCTAssertEqual(SendConditionsScore.scoreLabel(score: 100), .prime)
        XCTAssertEqual(SendConditionsScore.scoreLabel(score: 74), .good)
        XCTAssertEqual(SendConditionsScore.scoreLabel(score: 55), .good)
        XCTAssertEqual(SendConditionsScore.scoreLabel(score: 54), .fair)
        XCTAssertEqual(SendConditionsScore.scoreLabel(score: 35), .fair)
        XCTAssertEqual(SendConditionsScore.scoreLabel(score: 34), .poor)
        XCTAssertEqual(SendConditionsScore.scoreLabel(score: 0), .poor)
    }

    func testPercentileLabelBandsMatchWeb() {
        XCTAssertEqual(SendConditionsScore.percentileLabel(90), .prime)
        XCTAssertEqual(SendConditionsScore.percentileLabel(89), .good)
        XCTAssertEqual(SendConditionsScore.percentileLabel(75), .good)
        XCTAssertEqual(SendConditionsScore.percentileLabel(74), .fair)
        XCTAssertEqual(SendConditionsScore.percentileLabel(40), .fair)
        XCTAssertEqual(SendConditionsScore.percentileLabel(39), .poor)
        XCTAssertEqual(SendConditionsScore.percentileLabel(0), .poor)
    }

    // MARK: Same-hour percentile (issue #99)

    func testSameHourScoresStrideByTwentyFour() {
        let scores: [Int?] = (0..<96).map { $0 } // 4 full days of hours
        let series = SendConditionsScore.sameHourScores(scores, hourOfDay: 15)
        XCTAssertEqual(series, [15, 39, 63, 87])
    }

    func testSameHourScoresDropsNullsWithoutShifting() {
        var scores: [Int?] = Array(repeating: nil, count: 48)
        scores[3] = 42 // day 0 hour 3
        scores[27] = 7 // day 1 hour 3
        let series = SendConditionsScore.sameHourScores(scores, hourOfDay: 3)
        XCTAssertEqual(series, [42, 7])
    }

    func testDayRankRequiresTwentyDays() {
        XCTAssertNil(SendConditionsScore.dayRank(current: 50, dayScores: Array(repeating: 30, count: 19)))
        let rank = SendConditionsScore.dayRank(current: 50, dayScores: Array(repeating: 30, count: 20))
        XCTAssertEqual(rank?.below, 20)
        XCTAssertEqual(rank?.total, 20)
        XCTAssertEqual(rank?.percentile, 100)
    }

    func testDayRankCountsStrictlyBelow() {
        let dayScores = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100]
        let rank = SendConditionsScore.dayRank(current: 55, dayScores: dayScores)
        XCTAssertEqual(rank?.below, 10)
        XCTAssertEqual(rank?.total, 20)
        XCTAssertEqual(rank?.percentile, 50)
        // Ties do not count as below.
        XCTAssertEqual(SendConditionsScore.dayRank(current: 10, dayScores: dayScores)?.below, 0)
    }

    func testPercentileDetailFramesTopAndBottom() {
        XCTAssertEqual(SendConditionsScore.percentileDetail(100), "top 1%")
        XCTAssertEqual(SendConditionsScore.percentileDetail(50), "top 50%")
        XCTAssertEqual(SendConditionsScore.percentileDetail(57), "top 43%")
        XCTAssertEqual(SendConditionsScore.percentileDetail(43), "bottom 43%")
        XCTAssertEqual(SendConditionsScore.percentileDetail(10), "bottom 10%")
        XCTAssertEqual(SendConditionsScore.percentileDetail(0), "bottom 1%")
    }

    func testSameHourDaysAgoAccountsForEra5Lag() {
        XCTAssertEqual(SendConditionsScore.sameHourDaysAgo(index: 29, length: 30), 2)
        XCTAssertEqual(SendConditionsScore.sameHourDaysAgo(index: 0, length: 30), 31)
        XCTAssertEqual(SendConditionsScore.era5LagDays, 2)
    }

    func testWeekBucketMatchesWeb() {
        let reference = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-17
        XCTAssertEqual(SendConditionsScore.weekBucket(reference), 1_800_000_000 / (7 * 86_400))
    }

    // MARK: Open-Meteo parsing

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(type, from: data)
    }

    func testForecastParsing() throws {
        let response: OpenMeteo.ForecastResponse = try decode(OpenMeteo.ForecastResponse.self, from: """
        {"current": {"temperature_2m": 25.3, "relative_humidity_2m": 61.0}}
        """)
        let reading = try XCTUnwrap(OpenMeteo.currentReading(from: response))
        XCTAssertEqual(reading.tempC, 25.3)
        XCTAssertEqual(reading.humidity, 61.0)
    }

    func testForecastParsingMissingCurrentReturnsNil() throws {
        let response: OpenMeteo.ForecastResponse = try decode(OpenMeteo.ForecastResponse.self, from: "{}")
        XCTAssertNil(OpenMeteo.currentReading(from: response))
    }

    func testClimateSummaryComputesScoresAndRanges() throws {
        let response: OpenMeteo.ArchiveResponse = try decode(OpenMeteo.ArchiveResponse.self, from: """
        {"hourly": {
            "temperature_2m": [6, null, 35],
            "relative_humidity_2m": [0, null, 45]
        }}
        """)
        let summary = try XCTUnwrap(OpenMeteo.climateSummary(from: response))
        XCTAssertEqual(summary.scores, [100, nil, 20])
        XCTAssertEqual(summary.tempMin, 6, accuracy: 0.0001)
        XCTAssertEqual(summary.tempMax, 35, accuracy: 0.0001)
        XCTAssertEqual(summary.humMin, 0, accuracy: 0.0001)
        XCTAssertEqual(summary.humMax, 45, accuracy: 0.0001)
    }

    func testClimateSummaryEveryHourNullReturnsNil() throws {
        let response: OpenMeteo.ArchiveResponse = try decode(OpenMeteo.ArchiveResponse.self, from: """
        {"hourly": {"temperature_2m": [null], "relative_humidity_2m": [null]}}
        """)
        XCTAssertNil(OpenMeteo.climateSummary(from: response))
    }

    func testClimateSummaryMissingArraysReturnNil() throws {
        let response: OpenMeteo.ArchiveResponse = try decode(OpenMeteo.ArchiveResponse.self, from: "{}")
        XCTAssertNil(OpenMeteo.climateSummary(from: response))
    }

    func testURLsMatchWebEndpoints() {
        XCTAssertEqual(
            OpenMeteo.forecastURL(latitude: 13.75, longitude: 100.50).absoluteString,
            "https://api.open-meteo.com/v1/forecast?latitude=13.75&longitude=100.50&current=temperature_2m,relative_humidity_2m"
        )
        XCTAssertEqual(
            OpenMeteo.archiveURL(latitude: 13.75, longitude: 100.50, startDate: "2026-07-01", endDate: "2026-07-31").absoluteString,
            "https://archive-api.open-meteo.com/v1/era5?latitude=13.75&longitude=100.50&start_date=2026-07-01&end_date=2026-07-31&hourly=temperature_2m,relative_humidity_2m&timezone=auto"
        )
    }

    func testArchiveDateWindowUsesUTCAtNonUTCLocalBoundary() {
        // 00:30 in Bangkok on Aug 1 is still Jul 31 in UTC. A local-date
        // formatter would therefore produce a different ERA5 end date.
        let reference = isoDate("2026-07-31T17:30:00Z")
        let window = OpenMeteo.archiveDateWindow(referenceDate: reference)
        let bangkok = TimeZone(secondsFromGMT: 7 * 60 * 60)!
        let localEnd = LocalDateSupport.string(
            from: reference.addingTimeInterval(-Double(SendConditionsScore.era5LagDays * 86_400)),
            timeZone: bangkok
        )

        XCTAssertEqual(window.endDate, "2026-07-29")
        XCTAssertEqual(window.startDate, "2026-06-29")
        XCTAssertEqual(localEnd, "2026-07-30")
        XCTAssertNotEqual(window.endDate, localEnd)
    }

    func testSendConditionsCodableRoundTrip() throws {
        let conditions = SendConditions(
            tempC: 25.3,
            humidity: 61,
            score: 48,
            label: .fair,
            percentile: 72,
            daysBelow: 18,
            daysTotal: 25,
            hourOfDay: 14,
            hist: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(conditions)
        let decoded = try decoder.decode(SendConditions.self, from: data)
        XCTAssertEqual(decoded, conditions)
    }

    private func isoDate(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
