import Foundation

/// The account-owned payload written by the iPhone app for the home-screen
/// readiness widget. This is deliberately a small, Codable wire model: the
/// widget process must not fetch Supabase or HealthKit, and it must never
/// infer a score from a missing field.
public struct ReadinessWidgetSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let accountUserID: UUID
    public let accountEpoch: UInt64
    /// Gregorian local day (`yyyy-MM-dd`) for which the readiness row applies.
    public let day: String
    public let capturedAt: Date
    public let readiness: Int?
    public let readinessZone: String?
    public let readinessComputedAt: Date?
    public let acute: Double?
    public let chronic: Double?
    public let acwr: Double?
    public let phaseID: String?
    public let phaseName: String?
    public let phaseColorHex: String?
    public let phaseWeek: Int?
    public let phaseDay: Int?

    public init(
        accountUserID: UUID,
        accountEpoch: UInt64,
        day: String,
        capturedAt: Date = Date(),
        readiness: Int?,
        readinessZone: String?,
        readinessComputedAt: Date?,
        acute: Double?,
        chronic: Double?,
        acwr: Double?,
        phaseID: String?,
        phaseName: String?,
        phaseColorHex: String?,
        phaseWeek: Int?,
        phaseDay: Int?
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.accountUserID = accountUserID
        self.accountEpoch = accountEpoch
        self.day = day
        self.capturedAt = capturedAt

        // A score without a recognized zone is still useful; a zone without a
        // score is not. Keep the latter out of the store rather than letting a
        // stale label look like a fresh health result.
        let validReadiness = readiness.flatMap { (0...100).contains($0) ? $0 : nil }
        self.readiness = validReadiness
        self.readinessZone = validReadiness == nil
            ? nil
            : readinessZone.flatMap { zone in
                ["recover", "maintain", "push"].contains(zone) ? zone : nil
            }
        self.readinessComputedAt = validReadiness == nil ? nil : readinessComputedAt

        // ACWR is one atomic display group. Partial or non-finite values are
        // treated as no load data, never padded with zeroes.
        let validLoad = [acute, chronic, acwr].allSatisfy { value in
            guard let value else { return false }
            return value.isFinite && value >= 0
        }
        self.acute = validLoad ? acute : nil
        self.chronic = validLoad ? chronic : nil
        self.acwr = validLoad ? acwr : nil

        self.phaseID = phaseID?.isEmpty == false ? phaseID : nil
        self.phaseName = phaseName?.isEmpty == false ? phaseName : nil
        self.phaseColorHex = phaseColorHex?.isEmpty == false ? phaseColorHex : nil
        self.phaseWeek = phaseWeek.flatMap { $0 > 0 ? $0 : nil }
        self.phaseDay = phaseDay.flatMap { $0 > 0 ? $0 : nil }
    }

    /// The store rejects corrupt, old-schema, partial, or impossible data.
    /// A valid no-data snapshot has nil readiness and nil ACWR, which is
    /// intentionally different from a fabricated score/ratio of zero.
    public var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              !day.isEmpty,
              readiness.map({ (0...100).contains($0) }) ?? true,
              readiness == nil ? readinessZone == nil && readinessComputedAt == nil : true,
              phaseWeek.map({ $0 > 0 }) ?? true,
              phaseDay.map({ $0 > 0 }) ?? true
        else { return false }

        let loadValues = [acute, chronic, acwr].compactMap { $0 }
        guard loadValues.count == 0 || loadValues.count == 3 else { return false }
        return loadValues.allSatisfy { $0.isFinite && $0 >= 0 }
    }

    public func freshness(on localDay: String) -> ReadinessWidgetFreshness {
        guard isValid else { return .invalid }
        return day == localDay ? .current : .stale
    }
}

public enum ReadinessWidgetFreshness: Equatable, Sendable {
    case current
    case stale
    case invalid
}

/// These are the semantic colors used by the native Dashboard's ChartToken
/// and by the widget. Keeping the hex pairs in the Foundation-only shared
/// module means the two processes cannot silently drift apart.
public enum ReadinessWidgetSemanticToken: String, CaseIterable, Sendable {
    case focus
    case health
    case load
    case optimal
    case caution
    case alert
    case reference

    public var lightHex: String {
        switch self {
        case .focus: return "#5B5FC7"
        case .health, .optimal: return "#2E96F0"
        case .load: return "#7B83EB"
        case .caution: return "#DDB13A"
        case .alert: return "#E5743A"
        case .reference: return "#8E8E93"
        }
    }

    public var darkHex: String {
        switch self {
        case .focus, .load: return "#9296EE"
        case .health, .optimal: return "#4FB0FF"
        case .caution: return "#E8C24E"
        case .alert: return "#F0864C"
        case .reference: return "#A9A9B0"
        }
    }
}

public enum ReadinessWidgetReadinessBand: String, Sendable {
    case noData = "No data"
    case recover = "Recover"
    case maintain = "Maintain"
    case push = "Push"

    public var semanticToken: ReadinessWidgetSemanticToken {
        switch self {
        case .noData: return .reference
        case .recover: return .alert
        case .maintain: return .caution
        case .push: return .optimal
        }
    }
}

public enum ReadinessWidgetACWRBand: String, Sendable {
    case noData = "No data"
    case underTraining = "Under-training"
    case low = "Low"
    case optimal = "Optimal"
    case caution = "Caution"
    case danger = "Danger"

    public var semanticToken: ReadinessWidgetSemanticToken {
        switch self {
        case .noData: return .reference
        case .underTraining, .low: return .focus
        case .optimal: return .optimal
        case .caution: return .caution
        case .danger: return .alert
        }
    }
}

public enum ReadinessWidgetPresentation {
    /// The native Dashboard's recover/push thresholds are 40 and 70, with
    /// the boundary values remaining in the middle band.
    public static func readinessBand(_ score: Int?) -> ReadinessWidgetReadinessBand {
        guard let score else { return .noData }
        if score < 40 { return .recover }
        if score > 70 { return .push }
        return .maintain
    }

    /// Kept in lockstep with `TrainingMetrics.acwrStatus` and the web's
    /// `getACWRStatus`: under-training < .7, low through .8, optimal through
    /// 1.3, caution through 1.5, then danger.
    public static func acwrBand(_ ratio: Double?) -> ReadinessWidgetACWRBand {
        guard let ratio, ratio.isFinite else { return .noData }
        if ratio < 0.7 { return .underTraining }
        if ratio <= 0.8 { return .low }
        if ratio <= 1.3 { return .optimal }
        if ratio <= 1.5 { return .caution }
        return .danger
    }
}

public enum ReadinessWidgetTimelinePolicy {
    public static var localGregorianCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .current
        calendar.timeZone = .current
        return calendar
    }

    /// A day-boundary reload keeps the score frozen for the current local day
    /// while allowing a new day's row to appear even if the app is not opened.
    public static func nextReloadDate(
        after now: Date,
        calendar: Calendar = localGregorianCalendar
    ) -> Date {
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: start)
            ?? now.addingTimeInterval(86_400)
    }
}
