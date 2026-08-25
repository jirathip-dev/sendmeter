import XCTest
@testable import SendmeterCore

/// Pure helpers behind the #756 Send Conditions detail sheet: the same-hour
/// chart series, web-parity median/range saturation, and exact sheet copy.
final class SendConditionsDetailTests: XCTestCase {
    // MARK: Median (web `src/lib/boxplot.ts`)

    func testMedianMatchesWebLinearInterpolation() throws {
        XCTAssertNil(SendConditionsScore.median([]))
        XCTAssertEqual(try XCTUnwrap(SendConditionsScore.median([7])), 7, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(SendConditionsScore.median([1, 2, 3])), 2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(SendConditionsScore.median([1, 2, 3, 4])), 2.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(SendConditionsScore.median([10, 20, 30, 40])), 25, accuracy: 0.0001)
    }

    // MARK: Temperature-range saturation (web `isTempRangeSaturated`)

    func testTempRangeSaturationMatchesWeb() {
        // A hot climate where even the coolest hour is below the 16 °C
        // saturation point of the temperature sub-score.
        XCTAssertTrue(SendConditionsScore.isTempRangeSaturated(tempMin: 25, tempMax: 36))
        // A range dipping near 6 °C is not saturated even if today is hot.
        XCTAssertFalse(SendConditionsScore.isTempRangeSaturated(tempMin: 8, tempMax: 30))
        // Exactly at the 6 °C peak is never saturated.
        XCTAssertFalse(SendConditionsScore.isTempRangeSaturated(tempMin: 6, tempMax: 6))
        // A cold range is not the maxed-out case: 6-12 °C is close enough to
        // the friction peak to still produce a temperature contribution.
        XCTAssertFalse(SendConditionsScore.isTempRangeSaturated(tempMin: -20, tempMax: 0))
    }

    // MARK: Same-hour history slots

    func testHistoryBuildsEverySlotAndKeepsMissingDaysAsGaps() throws {
        let reference = isoDate("2026-08-23T10:00:00Z")
        let hist = try makeSummary(dayScores: [10, nil, 30, 40])
        let conditions = makeConditions(hist: hist, reference: reference)

        let history = try XCTUnwrap(SendConditionsHistoryBuilder.build(conditions: conditions))

        XCTAssertEqual(history.days.count, 4)
        XCTAssertEqual(history.days.map(\.score), [10, nil, 30, 40])
        XCTAssertEqual(history.days.map(\.daysAgo), [5, 4, 3, 2])
        // The null day keeps its slot: the next chronological day is still
        // daysAgo 3, not shifted into the missing day's position.
        XCTAssertNil(history.days[1].tempC)
        XCTAssertNil(history.days[1].humidity)
        XCTAssertEqual(try XCTUnwrap(history.days[2].tempC), 22, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(history.days[2].humidity), 50, accuracy: 0.0001)

        XCTAssertEqual(history.today.score, 20)
        XCTAssertEqual(try XCTUnwrap(history.today.tempC), 35, accuracy: 0.0001)
        XCTAssertTrue(history.today.isToday)
        XCTAssertEqual(history.allDays.count, 5)

        // Median excludes today and skips the null slot.
        XCTAssertEqual(history.median ?? -1, 30, accuracy: 0.0001)
        XCTAssertEqual(history.dateDomain?.lowerBound, history.days.first?.date)
        XCTAssertEqual(history.dateDomain?.upperBound, history.today.date)
    }

    func testHistoryIsNilWithoutHistory() {
        let histogram = conditionsWithoutHistory()
        XCTAssertNil(SendConditionsHistoryBuilder.build(conditions: histogram))
    }

    func testLegacyClimateSummaryDecodesWithoutRawArrays() throws {
        let json = """
        {"scores":[10,20],"tempMin":10,"tempMax":20,"humMin":30,"humMax":40}
        """
        let summary = try JSONDecoder().decode(ClimateSummary.self, from: Data(json.utf8))
        XCTAssertNil(summary.tempScores)
        XCTAssertNil(summary.humidityScores)
    }

    // MARK: Exact sheet copy

    func testHeadlineSuffixMatchesWeb() {
        XCTAssertEqual(SendConditionsDetails.headlineSuffix(percentile: 100, daysTotal: 30), "best of the last 30 days")
        XCTAssertEqual(SendConditionsDetails.headlineSuffix(percentile: 90, daysTotal: 30), "top 10%")
        XCTAssertEqual(SendConditionsDetails.headlineSuffix(percentile: 40, daysTotal: 30), "top 60%")
        XCTAssertNil(SendConditionsDetails.headlineSuffix(percentile: 39, daysTotal: 30))
        XCTAssertNil(SendConditionsDetails.headlineSuffix(percentile: 100, daysTotal: nil))
    }

    func testPercentilePhrasesMatchWeb() {
        XCTAssertEqual(SendConditionsDetails.percentilePhrase(100), "A standout window for here.")
        XCTAssertEqual(SendConditionsDetails.percentilePhrase(75), "A standout window for here.")
        XCTAssertEqual(SendConditionsDetails.percentilePhrase(40), "A typical day here.")
        XCTAssertEqual(SendConditionsDetails.percentilePhrase(0), "Below par for here.")
        XCTAssertEqual(
            SendConditionsDetails.percentileCallout(daysBelow: 18, daysTotal: 25, percentile: 72),
            "Better than 18 of the last 25 days at this time of day. A typical day here."
        )
        XCTAssertNil(SendConditionsDetails.percentileCallout(daysBelow: nil, daysTotal: 25, percentile: 72))
    }

    func testExplainerUsesWebHotClimateDriverText() throws {
        let reference = isoDate("2026-08-23T10:00:00Z")
        let hist = try makeSummary(dayScores: Array(repeating: 20, count: 30))
        let conditions = makeConditions(hist: hist, reference: reference)
        let text = SendConditionsDetails.explainer(conditions: conditions)

        XCTAssertTrue(text.contains("The headline compares right now"))
        XCTAssertTrue(text.contains("friction peaks near"))
        XCTAssertTrue(text.contains("Temperature is maxed out in this range"))
        XCTAssertTrue(text.contains("Weather is from Open-Meteo for your current location."))
    }

    // MARK: Color bands (web percentileColor / sendScoreColor)

    func testColorBandsMatchWebThresholds() {
        XCTAssertEqual(SendConditionsScore.percentileColorBand(75), .optimal)
        XCTAssertEqual(SendConditionsScore.percentileColorBand(40), .caution)
        XCTAssertEqual(SendConditionsScore.percentileColorBand(39), .alert)
        XCTAssertEqual(SendConditionsScore.scoreColorBand(55), .optimal)
        XCTAssertEqual(SendConditionsScore.scoreColorBand(35), .caution)
        XCTAssertEqual(SendConditionsScore.scoreColorBand(34), .alert)
    }

    // MARK: Fixtures

    private func makeSummary(dayScores: [Int?]) throws -> ClimateSummary {
        let dayCount = dayScores.count
        var scores: [Int?] = Array(repeating: nil, count: dayCount * 24)
        var temps: [Double?] = Array(repeating: nil, count: dayCount * 24)
        var hums: [Double?] = Array(repeating: nil, count: dayCount * 24)
        for (day, score) in dayScores.enumerated() {
            let index = day * 24 + 15
            scores[index] = score
            if score != nil {
                temps[index] = Double(20 + day)
                hums[index] = 50
            }
        }
        let validTemps = temps.compactMap { $0 }
        let validHums = hums.compactMap { $0 }
        return ClimateSummary(
            scores: scores,
            tempMin: validTemps.min() ?? 0,
            tempMax: validTemps.max() ?? 0,
            humMin: validHums.min() ?? 0,
            humMax: validHums.max() ?? 0,
            tempScores: temps,
            humidityScores: hums
        )
    }

    private func makeConditions(hist: ClimateSummary?, reference: Date) -> SendConditions {
        let score = SendConditionsScore.computeSendScore(tempC: 35, humidity: 45)
        let rank = hist.flatMap {
            SendConditionsScore.dayRank(
                current: score,
                dayScores: SendConditionsScore.sameHourScores(
                    $0.scores,
                    hourOfDay: 15
                )
            )
        }
        return SendConditions(
            tempC: 35,
            humidity: 45,
            score: score,
            label: .poor,
            percentile: rank?.percentile,
            daysBelow: rank?.below,
            daysTotal: rank?.total,
            hourOfDay: 15,
            hist: hist,
            fetchedAt: reference
        )
    }

    private func conditionsWithoutHistory() -> SendConditions {
        SendConditions(
            tempC: 35,
            humidity: 45,
            score: 20,
            label: .poor,
            percentile: nil,
            daysBelow: nil,
            daysTotal: nil,
            hourOfDay: 15,
            hist: nil,
            fetchedAt: isoDate("2026-08-23T10:00:00Z")
        )
    }

    private func isoDate(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
