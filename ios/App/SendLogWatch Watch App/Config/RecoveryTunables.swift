import Foundation

/// Every readiness-score constant. readiness = clamp(round(
///   50 + wHRV·z_hrv − wRHR·z_rhr + wSleep·min(z_sleep, sleepPosCapZ)
///      − loadPenaltyMax·p_load ), 0, 100)
struct RecoveryTunables {
    var wHRV: Double = 15          // HRV: best-validated marker, largest weight
    var wRHR: Double = 12          // RHR: robust but correlated with HRV
    var wSleep: Double = 8         // sleep: noisy nightly, partly in HRV already
    var sleepPosCapZ: Double = 1.0 // oversleeping can't supercharge the score
    var loadPenaltyMax: Double = 20
    var acwrPenaltyStart: Double = 1.3   // matches web "Optimal" band upper edge
    var acwrPenaltyFull: Double = 2.0    // full penalty at "Danger"
    var zClamp: Double = 2.0
    var baselineDays: Int = 30
    var minBaselineDays: Int = 7   // a z-term needs this much history else drops
    var sleepSigmaFloorH: Double = 0.5
    var zoneRecoverBelow: Int = 40
    var zonePushAbove: Int = 70
    var recentDaysKept: Int = 7    // local cache of daily rows re-upserted each refresh

    static let `default` = RecoveryTunables()
}
