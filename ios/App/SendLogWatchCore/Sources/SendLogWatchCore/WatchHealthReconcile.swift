import Foundation

// MARK: - Issue #802 AC3/AC4 — idempotent window reconcile + precedence

/// The watch's per-pass write plan: which rows to upsert, which date is the
/// relay/display metric, and which dates were actually reconciled.
public struct WatchHealthReconcilePlan: Equatable, Sendable {
    /// Rows to write. Historical rows are written only when the date has no
    /// existing row (insert-if-missing, #801); today follows the precedence
    /// decision.
    public let upserts: [WatchHealthMetric]
    /// The today metric the pass should display/relay: the computed metric
    /// when it wins, otherwise the retained server row.
    public let todayMetric: WatchHealthMetric?
    public let sourceDataDates: [String]
    public let reconciledDates: [String]

    public init(
        upserts: [WatchHealthMetric],
        todayMetric: WatchHealthMetric?,
        sourceDataDates: [String],
        reconciledDates: [String]
    ) {
        self.upserts = upserts
        self.todayMetric = todayMetric
        self.sourceDataDates = sourceDataDates
        self.reconciledDates = reconciledDates
    }

    public var reconciledCount: Int { reconciledDates.count }
}

/// Pure window reconciliation for the watch HealthKit path (#802 AC3),
/// mirroring the phone's #801 semantics with the #802 precedence applied:
///
/// - Today: the precedence policy (Guy's locked rule) decides. When the
///   date has a fresh, non-empty row the watch retains it; otherwise the
///   watch's computed metric wins the upsert. An empty (source-less)
///   compute never persists anything.
/// - Historical dates (`historicalUpserts`): insert-if-missing. An existing
///   historical row is never rewritten (the phone's row for that date is
///   the day's record), and the request itself is atomic against the
///   `(user_id, date)` key via conflict-ignore semantics.
/// - `allowReadinessOverwrite` is the #109 `ReadinessWritePolicy` decision
///   computed by the caller; when false and the date already carries a
///   scored row, the upsert keeps the existing score via
///   `omittingReadiness()` and lets the DB merge leave
///   readiness/zone/computed_at untouched.
public enum WatchHealthReconcile {
    /// Whole-window plan: today per precedence, historical insert-if-missing.
    public static func plan(
        freshMetrics: [WatchHealthMetric],
        existingToday: WatchHealthMetric?,
        existingDates: Set<String>,
        today: String,
        now: Date,
        timeZone: TimeZone,
        allowReadinessOverwrite: Bool = true
    ) -> WatchHealthReconcilePlan {
        let freshByDate = freshMetrics
            .filter { $0.hasSourceData }
            .reduce(into: [String: WatchHealthMetric]()) { result, metric in
                guard let current = result[metric.date] else {
                    result[metric.date] = metric
                    return
                }
                let currentComputedAt = current.computedAt ?? .distantPast
                let metricComputedAt = metric.computedAt ?? .distantPast
                if metricComputedAt > currentComputedAt {
                    result[metric.date] = metric
                }
            }
        let sourceDataDates = freshByDate.keys.sorted(by: >)

        var upserts: [WatchHealthMetric] = []
        var reconciledDates: [String] = []
        var todayMetric: WatchHealthMetric?

        for date in sourceDataDates {
            guard let fresh = freshByDate[date] else { continue }
            if date != today {
                if !existingDates.contains(date) {
                    upserts.append(fresh)
                    reconciledDates.append(date)
                }
                continue
            }
            let precedence = HealthMetricPrecedence.decide(
                candidate: HealthPrecedenceRow(
                    date: fresh.date,
                    computedAt: fresh.computedAt,
                    hasSourceData: fresh.hasSourceData
                ),
                existing: existingToday.map {
                    HealthPrecedenceRow(
                        date: $0.date,
                        computedAt: $0.computedAt,
                        hasSourceData: $0.hasSourceData
                    )
                },
                writer: .watch,
                now: now,
                timeZone: timeZone
            )
            switch precedence {
            case .discardCandidate:
                break
            case .retainExisting:
                // Existing fresh non-empty row wins; display it.
                todayMetric = existingToday
            case .writeCandidate:
                let existingScored = existingToday?.readiness != nil
                let upsert = allowReadinessOverwrite || !existingScored
                    ? fresh
                    : fresh.omittingReadiness()
                upserts.append(upsert)
                reconciledDates.append(date)
                todayMetric = allowReadinessOverwrite || !existingScored ? fresh : existingToday
            }
        }

        return WatchHealthReconcilePlan(
            upserts: upserts,
            todayMetric: todayMetric,
            sourceDataDates: sourceDataDates,
            reconciledDates: reconciledDates
        )
    }

    /// Historical dates the watch may fill: source-backed, not today, and
    /// absent from the server (insert-if-missing semantics).
    public static func historicalUpserts(
        freshMetrics: [WatchHealthMetric],
        existingDates: Set<String>,
        today: String
    ) -> [WatchHealthMetric] {
        freshMetrics
            .filter {
                $0.hasSourceData
                    && $0.date != today
                    && !existingDates.contains($0.date)
            }
            .sorted { $0.date > $1.date }
    }
}
