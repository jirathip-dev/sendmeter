import Foundation

/// What triggered a sync — distinguishes an app-driven HealthKit
/// foreground/background sync ("automatic") from an explicit user-refresh
/// gesture ("manual" — always authoritative, bypasses the lock below).
/// There is currently NO manual-refresh gesture in the app: every existing
/// `syncNow` call site (cold-launch background registration, foreground
/// re-sync on visibilitychange) is app-driven, not a user tap, so all of
/// them pass `.automatic`. `.manual` is reserved for a future pull-to-refresh
/// and for `clearAndResync` (an explicit user action handled by its own,
/// separate always-overwrite code path — it doesn't call `syncNow` at all).
public enum SyncTrigger {
    case automatic
    case manual
}

/// #109: readiness flipped from a good morning score to a worse one by
/// afternoon. Root cause was every automatic HealthKit re-sync (background
/// delivery, plus a foreground re-sync on every app open, can both fire
/// repeatedly through the day) recomputing and overwriting today's
/// `health_metrics` row — and several inputs, resting HR chief among them,
/// aren't guaranteed to be finalized in the morning (Apple's daily
/// resting-HR estimate is frequently timestamped mid-day). Bounding the
/// HealthKit query window can't fix this: it risks making today's RHR nil
/// outright (and starving its 30-day baseline below `minBaselineDays`,
/// silently zeroing a 12-point term), and `HKQuery.predicateForSamples`'s
/// default (non-strict) matching lets a wide-interval sample straddle any
/// window regardless.
///
/// Instead this locks a day's **readiness** at the write layer: once today's
/// row has been scored, an automatic sync after noon leaves `readiness`/
/// `zone`/`computed_at` alone rather than overwriting them with whatever
/// HealthKit reports right now. It does NOT gate the biometric columns
/// (hrv/rhr/sleep/resp/mass) — the caller (`HealthSyncManager.syncNow`)
/// always re-reads and re-upserts those on every sync, locked or not, so a
/// metric HealthKit only finishes writing mid-afternoon (sleep stages are a
/// common case) still lands in the row for that day. Readiness is the frozen
/// morning score; the biometric columns stay current through the day.
///
/// Before noon — the same cutoff `Calendar.nightWindow` already uses for
/// HRV/sleep/resp, since overnight data can still be trickling in —
/// automatic recomputes of readiness are still allowed, and the very first
/// score of the day is always written even if that happens to land in the
/// afternoon (a day must never end up with no readiness at all just because
/// the phone was locked all morning). Manual (user-initiated) syncs are
/// always authoritative and bypass the lock entirely.
public enum ReadinessWritePolicy {
    /// - Parameters:
    ///   - existingReadiness: today's row's `readiness`, if a row exists.
    ///   - existingRowDate: today's row's own `date` column (as fetched),
    ///     not the caller's query filter. Self-defense against a caller bug
    ///     (e.g. a stale cache, or a filter that silently matched the wrong
    ///     row) locking the wrong day — passed as a `date`-column string
    ///     rather than a decoded timestamp so callers never need to decode a
    ///     `timestamptz` (a source of decode-mismatch failures) just to
    ///     consult this policy.
    ///   - now: current time; also used to derive "today" for the
    ///     self-defense check.
    ///   - calendar: sole time-zone authority for the policy — both the noon
    ///     cutoff and the "today" date string are derived from it, so a
    ///     non-device-timezone calendar (tests do this) stays internally
    ///     consistent.
    public static func shouldOverwriteReadiness(
        existingReadiness: Int?,
        existingRowDate: String?,
        now: Date,
        trigger: SyncTrigger,
        calendar: Calendar = .gregorianLocal
    ) -> Bool {
        switch trigger {
        case .manual:
            return true
        case .automatic:
            guard existingReadiness != nil, existingRowDate == now.dateString(in: calendar) else {
                return true
            }
            let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
            return now < noon
        }
    }
}
