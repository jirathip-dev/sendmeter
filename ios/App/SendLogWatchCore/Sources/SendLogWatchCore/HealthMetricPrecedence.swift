import Foundation
import SendLogHealthCore

// MARK: - Issue #802 — dual-source precedence (Guy's locked rule)

/// Which writer produced a candidate `health_metrics` row. The two write
/// sites (the iPhone's native app and the watch app) share this policy so
/// the server row for a `(user_id, date)` key has one deterministic winner.
public enum HealthMetricWriter: String, Equatable, Sendable {
    case phone
    case watch
}

/// The server-row facts the precedence policy needs. Deliberately no
/// HealthKit or Supabase types: both write sites already own their row
/// models, and this struct keeps the policy in the shared pure package.
public struct HealthPrecedenceRow: Equatable, Sendable {
    /// The row's calendar date, YYYY-MM-DD.
    public let date: String
    /// The row's `computed_at`. Nil for legacy rows written by the shipped
    /// plugin whose timestamp was never decoded.
    public let computedAt: Date?
    /// Whether at least one raw biometric column is present. A row carrying
    /// only readiness/zone (an old plugin artifact) is NOT source-backed and
    /// counts as empty under the locked rule.
    public let hasSourceData: Bool

    public init(date: String, computedAt: Date?, hasSourceData: Bool) {
        self.date = date
        self.computedAt = computedAt
        self.hasSourceData = hasSourceData
    }
}

/// The deterministic outcome of one precedence decision.
public enum HealthPrecedenceDecision: Equatable, Sendable {
    /// The writer's freshly computed row may upsert.
    case writeCandidate
    /// The existing row wins; the writer must not touch the date.
    case retainExisting
    /// The candidate has no source data; nothing should be written at all.
    case discardCandidate
}

/// Issue #802 AC4 — deterministic winner for the same `(user_id, date)`
/// health row, when both the iPhone and the watch can write it (Guy's rule,
/// locked 2026-08-25): **the watch's row wins when the phone's row for the
/// date is stale/empty; the phone wins whenever it has a fresh, non-empty
/// row for that date.** No last-write-wins flapping, no duplicate rows.
///
/// Freshness is deterministic and clock-less: a row is FRESH iff
/// `computedAt` falls on the **same local day as `now`** (in the writer's
/// time zone). A row computed yesterday — however recent — is stale for
/// today's write, which is exactly the "phone's stale score must not clobber
/// the watch's fresh morning data" case.
///
/// Watch semantics: the watch writes at most one row per date per phone
/// row — if a fresh non-empty row already exists (whether the phone's or a
/// row the watch itself wrote earlier this morning), the watch stops; the
/// row then converges deterministically and never flaps.
public enum HealthMetricPrecedence {
    /// A row is fresh when its `computedAt` is on the same local calendar
    /// day as `now`.
    public static func isFresh(
        _ row: HealthPrecedenceRow,
        now: Date,
        timeZone: TimeZone
    ) -> Bool {
        guard let computedAt = row.computedAt else { return false }
        let calendar = Calendar.gregorianLocal
        return computedAt.dateString(in: calendar) == now.dateString(in: calendar)
    }

    public static func decide(
        candidate: HealthPrecedenceRow,
        existing: HealthPrecedenceRow?,
        writer: HealthMetricWriter,
        now: Date,
        timeZone: TimeZone
    ) -> HealthPrecedenceDecision {
        // Never persist a source-less row — an empty compute must never
        // clobber a fresh row from the other source (#801's no-empty-day
        // invariant, held here for both write sites).
        guard candidate.hasSourceData else {
            return .discardCandidate
        }

        switch writer {
        case .phone:
            // The phone's freshly computed row is authoritative: by the time
            // a phone pass produces a candidate, the phone HAS a fresh,
            // non-empty row for the date and wins over any watch row.
            // (The phone's own #109 freeze and #801 insert-if-missing rules
            // still gate whether that winner is written; this policy decides
            // the SOURCE winner.)
            return .writeCandidate
        case .watch:
            // The watch fills only stale/empty dates. A fresh non-empty row
            // (the phone's, or the watch's own earlier pass) is retained.
            if let existing, existing.hasSourceData,
               isFresh(existing, now: now, timeZone: timeZone) {
                return .retainExisting
            }
            return .writeCandidate
        }
    }
}
