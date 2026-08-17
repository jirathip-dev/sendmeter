import Foundation

/// The readiness part of a single recompute pass: what to relay/display and
/// what to upsert. Mirrors the shipped plugin's `performPass` split — the
/// upsert payload and the relayed snapshot carry DIFFERENT readiness when a
/// pass keeps an existing score:
///
/// - The upsert is the biometric columns only (readiness/zone/computedAt nil,
///   so the synthesized encoder omits them) and PostgREST's
///   `resolution=merge-duplicates` ON CONFLICT leaves the existing
///   readiness/zone/computed_at untouched.
/// - The relay/display metric keeps the existing scored reading (never a
///   blanked score), and — via `HealthMetric.computedAt` being optional — never
///   stamps a fresh `computed_at` over a kept row.
public struct ReadinessPublishPlan: Equatable, Sendable {
    /// What to relay to the watch and publish to the UI. Never a fabricated
    /// score and never a blanked one: a nil fresh score keeps the existing
    /// today reading.
    public let relayMetric: HealthMetric
    /// What to upsert. Fresh biometrics always; readiness/zone/computedAt nil
    /// exactly when keeping an existing score.
    public let upsertMetric: HealthMetric
}

/// The #661 F1/#109 decision for a readiness recompute pass, pure and
/// unit-tested (mirrors the plugin's `HealthSyncManager.performPass`).
///
/// `allowReadinessOverwrite` is the #109 `ReadinessWritePolicy.shouldOverwriteReadiness`
/// decision, computed by the caller; this type owns the *publish* half — never
/// letting a nil fresh score replace a scored reading, and never letting a
/// locked pass write readiness at all.
public enum ReadinessSyncPolicy {
    public static func plan(
        existingToday: HealthMetric?,
        freshlyComputed: HealthMetric,
        allowReadinessOverwrite: Bool
    ) -> ReadinessPublishPlan {
        // A fresh score is written when the policy allows and one exists.
        if allowReadinessOverwrite, freshlyComputed.readiness != nil {
            return ReadinessPublishPlan(
                relayMetric: freshlyComputed,
                upsertMetric: freshlyComputed
            )
        }
        // Otherwise keep today's scored reading if there is one: relay it and
        // re-upsert only the fresh biometrics (readiness/zone/computedAt nil →
        // omitted → DB row keeps the existing score + timestamp).
        if let existingToday, existingToday.date == freshlyComputed.date,
           existingToday.readiness != nil {
            return ReadinessPublishPlan(
                relayMetric: existingToday,
                upsertMetric: freshlyComputed.omittingReadiness()
            )
        }
        // No prior scored reading to keep: relay the honest fresh result (which
        // may itself be nil — a genuinely empty HealthKit read on a first
        // sync) and upsert the fresh biometrics without readiness.
        return ReadinessPublishPlan(
            relayMetric: freshlyComputed,
            upsertMetric: freshlyComputed.omittingReadiness()
        )
    }
}
