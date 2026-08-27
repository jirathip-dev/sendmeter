import Foundation

/// Foundation-only widget contract shared by the native app and its separate
/// WidgetKit process. It lives in the health core package because the app and
/// extension need one testable source of truth for the Codable wire shape,
/// App Group store, Gregorian day boundary, and semantic colors; it has no
/// HealthKit, Supabase, or WidgetKit dependency.
public struct ReadinessWidgetSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    private static let validReadinessZones = Set(["recover", "maintain", "push"])

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
                Self.validReadinessZones.contains(zone) ? zone : nil
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

        self.phaseID = Self.nonEmptyPhaseValue(phaseID)
        self.phaseName = Self.nonEmptyPhaseValue(phaseName)
        self.phaseColorHex = Self.nonEmptyPhaseValue(phaseColorHex)
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
              readinessZone.map({ Self.validReadinessZones.contains($0) }) ?? true,
              readiness == nil ? readinessZone == nil && readinessComputedAt == nil : true,
              phaseID.map({ Self.hasNonEmptyPhaseValue($0) }) ?? true,
              phaseName.map({ Self.hasNonEmptyPhaseValue($0) }) ?? true,
              phaseColorHex.map({ Self.hasNonEmptyPhaseValue($0) }) ?? true,
              phaseWeek.map({ $0 > 0 }) ?? true,
              phaseDay.map({ $0 > 0 }) ?? true
        else { return false }

        let loadValues = [acute, chronic, acwr].compactMap { $0 }
        guard loadValues.count == 0 || loadValues.count == 3 else { return false }
        return loadValues.allSatisfy { $0.isFinite && $0 >= 0 }
    }

    private static func nonEmptyPhaseValue(_ value: String?) -> String? {
        guard let value, hasNonEmptyPhaseValue(value) else { return nil }
        return value
    }

    private static func hasNonEmptyPhaseValue(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func freshness(on localDay: String) -> ReadinessWidgetFreshness {
        guard isValid else { return .invalid }
        return day == localDay ? .current : .stale
    }

    /// The WidgetKit reload budget is about visible changes, not capture
    /// timestamps. Keep owner/day and every rendered field in the identity,
    /// while allowing a repeated foreground publication to refresh the stored
    /// capture time without spending another reload request.
    public func matchesPublishedContent(of other: Self) -> Bool {
        schemaVersion == other.schemaVersion
            && accountUserID == other.accountUserID
            && accountEpoch == other.accountEpoch
            && day == other.day
            && readiness == other.readiness
            && readinessZone == other.readinessZone
            && acute == other.acute
            && chronic == other.chronic
            && acwr == other.acwr
            && phaseID == other.phaseID
            && phaseName == other.phaseName
            && phaseColorHex == other.phaseColorHex
            && phaseWeek == other.phaseWeek
            && phaseDay == other.phaseDay
    }
}

public enum ReadinessWidgetFreshness: Equatable, Sendable {
    case current
    case stale
    case invalid
}

/// The app process and the WidgetKit process both use this exact App Group
/// payload. The injected `UserDefaults` initializer makes save/load/clear
/// behavior testable without touching a user's real App Group in tests.
public final class ReadinessWidgetStore {
    public static let appGroup = "group.com.jirathip.sendlog"
    public static let snapshotKey = "sendmeter.readiness-widget.snapshot"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public static var appGroupStore: ReadinessWidgetStore? {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return nil }
        return ReadinessWidgetStore(defaults: defaults)
    }

    public func load() -> ReadinessWidgetSnapshot? {
        guard let data = defaults.data(forKey: Self.snapshotKey),
              let snapshot = try? JSONDecoder().decode(
                ReadinessWidgetSnapshot.self,
                from: data
              ),
              snapshot.isValid
        else { return nil }
        return snapshot
    }

    public func save(_ snapshot: ReadinessWidgetSnapshot) {
        guard snapshot.isValid,
              let data = try? JSONEncoder().encode(snapshot)
        else { return }
        defaults.set(data, forKey: Self.snapshotKey)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.snapshotKey)
    }
}

/// Publication-level dedupe for AppModel paths that converge during one
/// foreground refresh. A changed display payload still requests a reload;
/// only capture-time-only changes are suppressed.
public enum ReadinessWidgetPublicationPolicy {
    public static func shouldReload(
        previous: ReadinessWidgetSnapshot?,
        next: ReadinessWidgetSnapshot
    ) -> Bool {
        guard let previous else { return true }
        return !previous.matchesPublishedContent(of: next)
    }
}

public enum ReadinessWidgetOwnershipPolicy {
    public static func canPublish(
        _ snapshot: ReadinessWidgetSnapshot,
        currentUserID: UUID?,
        currentEpoch: UInt64
    ) -> Bool {
        snapshot.isValid
            && snapshot.accountUserID == currentUserID
            && snapshot.accountEpoch == currentEpoch
    }

    /// A reset advances the in-memory epoch. Keep a current same-account
    /// snapshot visible while its replacement refreshes, but never let an old
    /// account or a signed-out state remain in the App Group.
    public static func shouldClearOnReset(
        snapshotOwner: UUID?,
        currentUserID: UUID?
    ) -> Bool {
        guard let currentUserID else { return true }
        return snapshotOwner != currentUserID
    }
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
    /// Prefer the stored zone used by Dashboard for both the label and color.
    /// The score fallback preserves display for older partial snapshots that
    /// have a valid score but no zone.
    public static func readinessBand(
        zone: String?,
        fallbackScore: Int?
    ) -> ReadinessWidgetReadinessBand {
        guard let zone else { return readinessBand(fallbackScore) }
        switch zone {
        case "recover": return .recover
        case "maintain": return .maintain
        case "push": return .push
        default: return .noData
        }
    }

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

    /// Shared by the writer and the WidgetKit process. The supplied calendar
    /// contributes only its time zone; the output is always Gregorian AD,
    /// even when the device's region uses a Buddhist or other local calendar.
    public static func localDayString(
        for date: Date,
        calendar: Calendar = localGregorianCalendar
    ) -> String {
        var style = Date.ISO8601FormatStyle().year().month().day()
        style.timeZone = calendar.timeZone
        return style.format(date)
    }

    /// At local midnight, keep non-daily context visible while honestly
    /// removing yesterday's readiness score until today's row is published.
    public static func boundarySnapshot(
        from snapshot: ReadinessWidgetSnapshot?,
        at date: Date,
        calendar: Calendar = localGregorianCalendar
    ) -> ReadinessWidgetSnapshot? {
        guard let snapshot, snapshot.isValid else { return nil }
        return ReadinessWidgetSnapshot(
            accountUserID: snapshot.accountUserID,
            accountEpoch: snapshot.accountEpoch,
            day: localDayString(for: date, calendar: calendar),
            capturedAt: date,
            readiness: nil,
            readinessZone: nil,
            readinessComputedAt: nil,
            acute: snapshot.acute,
            chronic: snapshot.chronic,
            acwr: snapshot.acwr,
            phaseID: snapshot.phaseID,
            phaseName: snapshot.phaseName,
            phaseColorHex: snapshot.phaseColorHex,
            phaseWeek: snapshot.phaseWeek,
            phaseDay: snapshot.phaseDay
        )
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
