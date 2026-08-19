import Foundation

/// "Send conditions" (SL-69, web parity #631): friction for climbing is best
/// when it's cool and dry, so temperature + humidity blend into a 0–100 send
/// score. Every threshold mirrors `src/lib/weather.ts` EXACTLY — same
/// formulas, same label bands, same same-hour-of-day percentile rule — so
/// the native card and the web card can never disagree about a reading.
public enum SendConditionsLabel: String, Codable, Equatable, Sendable {
    case prime = "Prime"
    case good = "Good"
    case fair = "Fair"
    case poor = "Poor"
}

public struct ClimateSummary: Codable, Equatable, Sendable {
    /// Hourly send scores over the ~30-day window, aligned to LOCAL time
    /// (index `i` = day `floor(i/24)`, hour `i%24` — the archive is
    /// requested with `timezone=auto`). A null hour the archive didn't
    /// return is kept as a placeholder (not skipped) so the day/hour index
    /// arithmetic stays valid.
    public var scores: [Int?]
    public var tempMin: Double
    public var tempMax: Double
    public var humMin: Double
    public var humMax: Double

    public init(scores: [Int?], tempMin: Double, tempMax: Double, humMin: Double, humMax: Double) {
        self.scores = scores
        self.tempMin = tempMin
        self.tempMax = tempMax
        self.humMin = humMin
        self.humMax = humMax
    }
}

public struct SendConditions: Codable, Equatable, Sendable {
    public var tempC: Double
    public var humidity: Double
    public var score: Int
    public var label: SendConditionsLabel
    /// Where right now ranks against the SAME local hour of day on the last
    /// ~30 days (issue #99) — 0–100, or nil when there are fewer than
    /// `minPercentileDays` such days. This is the signal that matters in a
    /// hot climate where the absolute score is always "Poor".
    public var percentile: Int?
    public var daysBelow: Int?
    public var daysTotal: Int?
    public var hourOfDay: Int
    public var hist: ClimateSummary?
    public var fetchedAt: Date

    public init(
        tempC: Double,
        humidity: Double,
        score: Int,
        label: SendConditionsLabel,
        percentile: Int?,
        daysBelow: Int?,
        daysTotal: Int?,
        hourOfDay: Int,
        hist: ClimateSummary?,
        fetchedAt: Date
    ) {
        self.tempC = tempC
        self.humidity = humidity
        self.score = score
        self.label = label
        self.percentile = percentile
        self.daysBelow = daysBelow
        self.daysTotal = daysTotal
        self.hourOfDay = hourOfDay
        self.hist = hist
        self.fetchedAt = fetchedAt
    }
}

/// The trigger for a weather refresh. Automatic lifecycle refreshes are
/// freshness-gated; an explicit user gesture always gets to try again.
public enum WeatherRefreshTrigger: Equatable, Sendable {
    case appear
    case foreground
    case manual
}

/// Web-parity freshness policy for Send Conditions. The clock and the last
/// successful reading are supplied by the caller so the boundary is pure and
/// testable without waiting.
public struct WeatherRefreshPolicy: Equatable, Sendable {
    public static let defaultFreshnessWindow: TimeInterval = 30 * 60

    public let freshnessWindow: TimeInterval

    public init(freshnessWindow: TimeInterval = WeatherRefreshPolicy.defaultFreshnessWindow) {
        self.freshnessWindow = freshnessWindow
    }

    public func shouldRefresh(
        trigger: WeatherRefreshTrigger,
        lastFetchedAt: Date?,
        now: Date
    ) -> Bool {
        guard trigger != .manual else { return true }
        guard let lastFetchedAt else { return true }
        return now.timeIntervalSince(lastFetchedAt) > freshnessWindow
    }
}

/// The pure scoring surface — the platform layer fetches raw weather, this
/// turns it into the card's numbers.
public enum SendConditionsScore {
    /// How many days before "now" entry `index` of a `sameHourScores(...)`
    /// result of length `length` represents — Open-Meteo's ERA5 archive
    /// lags realtime by 2 days, so the most recent entry is 2 days old, not
    /// 1 (the web's `ERA5_LAG_DAYS`).
    public static let era5LagDays = 2

    /// The minimum number of same-hour days before a rank is claimed.
    public static let minPercentileDays = 20

    /// Weekly cache bucket — the local climate distribution barely moves
    /// week to week, so the (heavier) archive refetches at most once per
    /// 7 days (the web's `weekBucket`).
    public static func weekBucket(_ now: Date) -> Int {
        Int(now.timeIntervalSince1970) / (7 * 86_400)
    }

    public static func tempFrictionScore(tempC: Double) -> Double {
        min(100, max(0, 100 - abs(tempC - 6) * 6))
    }

    public static func humidityFrictionScore(humidity: Double) -> Double {
        min(100, max(0, 100 - humidity * 1.1))
    }

    /// Overall send score: 60% temperature, 40% humidity.
    public static func computeSendScore(tempC: Double, humidity: Double) -> Int {
        Int((0.6 * tempFrictionScore(tempC: tempC) + 0.4 * humidityFrictionScore(humidity: humidity)).rounded())
    }

    /// Build the current reading even when the optional archive context is
    /// unavailable. An archive failure removes only the percentile context;
    /// it must never erase a successful current-weather score.
    public static func makeConditions(
        tempC: Double,
        humidity: Double,
        hourOfDay: Int,
        climate: ClimateSummary?,
        fetchedAt: Date
    ) -> SendConditions {
        let score = computeSendScore(tempC: tempC, humidity: humidity)
        let rank = climate.flatMap { climate in
            dayRank(
                current: score,
                dayScores: sameHourScores(climate.scores, hourOfDay: hourOfDay)
            )
        }
        return SendConditions(
            tempC: tempC,
            humidity: humidity,
            score: score,
            label: scoreLabel(score: score),
            percentile: rank?.percentile,
            daysBelow: rank?.below,
            daysTotal: rank?.total,
            hourOfDay: hourOfDay,
            hist: climate,
            fetchedAt: fetchedAt
        )
    }

    public static func scoreLabel(score: Int) -> SendConditionsLabel {
        if score >= 75 { return .prime }
        if score >= 55 { return .good }
        if score >= 35 { return .fair }
        return .poor
    }

    /// Label for a same-hour-of-day percentile (issue #99): ≥90 is the top
    /// decile ("Prime"), ≥75 "Good", ≥40 "Fair", else "Poor" — aligned with
    /// the web's `percentileLabel`.
    public static func percentileLabel(_ percentile: Int) -> SendConditionsLabel {
        if percentile >= 90 { return .prime }
        if percentile >= 75 { return .good }
        if percentile >= 40 { return .fair }
        return .poor
    }

    /// Every day's send score at a given local hour-of-day, chronological,
    /// nulls dropped — the series `dayRank` compares `current` against:
    /// same time of day, different days.
    public static func sameHourScores(_ scores: [Int?], hourOfDay: Int) -> [Int] {
        stride(from: hourOfDay, to: scores.count, by: 24).compactMap { scores[$0] }
    }

    /// Where `current` ranks among `dayScores`: the count scoring strictly
    /// lower, the total, and the resulting percentile. Nil when there are
    /// fewer than 20 days — too sparse to claim a rank at a single hour.
    public static func dayRank(
        current: Int,
        dayScores: [Int]
    ) -> (below: Int, total: Int, percentile: Int)? {
        let total = dayScores.count
        guard total >= minPercentileDays else { return nil }
        let below = dayScores.filter { $0 < current }.count
        return (below, total, Int((Double(below) / Double(total) * 100).rounded()))
    }

    /// The card's compact percentile detail: percentile reads as "top N%"
    /// ≥50 and "bottom N%" below (printing "top 100%" at percentile 0 would
    /// be nonsense).
    public static func percentileDetail(_ percentile: Int) -> String {
        percentile >= 50
            ? "top \(max(1, 100 - percentile))%"
            : "bottom \(max(1, percentile))%"
    }

    public static func sameHourDaysAgo(index: Int, length: Int) -> Int {
        length - index - 1 + era5LagDays
    }
}

/// Open-Meteo request/response shapes — the web's exact endpoints and
/// params, so the network layer stays thin and this parsing is unit-testable
/// with fixture JSON (no network in tests).
public enum OpenMeteo {
    public struct ArchiveDateWindow: Equatable, Sendable {
        public let startDate: String
        public let endDate: String

        public init(startDate: String, endDate: String) {
            self.startDate = startDate
            self.endDate = endDate
        }
    }

    /// Current weather, keyless public API. Coordinates are formatted with
    /// 2 decimals (~1 km, the web's `toFixed(2)`) so we don't ship a precise
    /// location off-device.
    public static func forecastURL(latitude: Double, longitude: Double) -> URL {
        URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(String(format: "%.2f", latitude))&longitude=\(String(format: "%.2f", longitude))&current=temperature_2m,relative_humidity_2m")!
    }

    /// Last ~30 days of hourly local weather from the ERA5 archive, with
    /// `timezone=auto` so the hourly arrays align to LOCAL time rather than
    /// UTC. The most recent complete day it can serve lags realtime by
    /// `era5LagDays`.
    public static func archiveURL(
        latitude: Double,
        longitude: Double,
        startDate: String,
        endDate: String
    ) -> URL {
        URL(string: "https://archive-api.open-meteo.com/v1/era5?latitude=\(String(format: "%.2f", latitude))&longitude=\(String(format: "%.2f", longitude))&start_date=\(startDate)&end_date=\(endDate)&hourly=temperature_2m,relative_humidity_2m&timezone=auto")!
    }

    /// Match the web's `date.toISOString().slice(0, 10)`: archive request
    /// dates are UTC calendar dates even when the device is in another zone.
    public static func archiveDateWindow(referenceDate: Date) -> ArchiveDateWindow {
        let end = referenceDate.addingTimeInterval(-Double(SendConditionsScore.era5LagDays * 86_400))
        let start = end.addingTimeInterval(-Double(30 * 86_400))
        let utc = TimeZone(secondsFromGMT: 0)!
        return ArchiveDateWindow(
            startDate: LocalDateSupport.string(from: start, timeZone: utc),
            endDate: LocalDateSupport.string(from: end, timeZone: utc)
        )
    }

    public struct ForecastResponse: Decodable, Sendable {
        public struct Current: Decodable, Sendable {
            public var temperature_2m: Double?
            public var relative_humidity_2m: Double?
        }

        public var current: Current?

        public init(current: Current? = nil) {
            self.current = current
        }
    }

    public struct ArchiveResponse: Decodable, Sendable {
        public struct Hourly: Decodable, Sendable {
            public var temperature_2m: [Double?]?
            public var relative_humidity_2m: [Double?]?
        }

        public var hourly: Hourly?

        public init(hourly: Hourly? = nil) {
            self.hourly = hourly
        }
    }

    public static func currentReading(from response: ForecastResponse) -> (tempC: Double, humidity: Double)? {
        guard let tempC = response.current?.temperature_2m,
              let humidity = response.current?.relative_humidity_2m
        else { return nil }
        return (tempC, humidity)
    }

    /// Turn the archive's hourly arrays into a ClimateSummary. Missing hours
    /// are pushed as null (NOT skipped) — skipping would shift every later
    /// index off its day/hour-of-day slot and break `sameHourScores`.
    /// Returns nil only when every hour is null.
    public static func climateSummary(from response: ArchiveResponse) -> ClimateSummary? {
        guard let temps = response.hourly?.temperature_2m,
              let hums = response.hourly?.relative_humidity_2m
        else { return nil }
        var scores: [Int?] = []
        var tempMin = Double.infinity
        var tempMax = -Double.infinity
        var humMin = Double.infinity
        var humMax = -Double.infinity
        for index in 0..<max(temps.count, hums.count) {
            guard index < temps.count, index < hums.count,
                  let temp = temps[index], let humidity = hums[index]
            else {
                scores.append(nil)
                continue
            }
            scores.append(SendConditionsScore.computeSendScore(tempC: temp, humidity: humidity))
            tempMin = min(tempMin, temp)
            tempMax = max(tempMax, temp)
            humMin = min(humMin, humidity)
            humMax = max(humMax, humidity)
        }
        guard tempMin.isFinite else { return nil }
        return ClimateSummary(scores: scores, tempMin: tempMin, tempMax: tempMax, humMin: humMin, humMax: humMax)
    }
}

/// The honest-failure surface for the weather path (#631): a denied location
/// and a failed/empty fetch both degrade to "Unavailable" in the UI — the
/// card never fabricates a score.
public enum WeatherError: Error, Equatable, LocalizedError {
    case locationDenied
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .locationDenied: return "Location permission denied."
        case .unavailable: return "Send conditions are unavailable."
        }
    }
}
