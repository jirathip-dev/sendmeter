import Foundation

/// Every readiness-score constant. readiness = clamp(round(
///   50 + wHRV·z_hrv − wRHR·z_rhr + wSleep·min(z_sleep, sleepPosCapZ)
///      − loadPenaltyMax·p_load ), 0, 100)
public struct RecoveryTunables {
    public var wHRV: Double = 15          // HRV: best-validated marker, largest weight
    public var wRHR: Double = 12          // RHR: robust but correlated with HRV
    public var wSleep: Double = 8         // sleep: noisy nightly, partly in HRV already
    public var sleepPosCapZ: Double = 1.0 // oversleeping can't supercharge the score
    public var loadPenaltyMax: Double = 20
    public var acwrPenaltyStart: Double = 1.3   // matches web "Optimal" band upper edge
    public var acwrPenaltyFull: Double = 2.0    // full penalty at "Danger"
    public var zClamp: Double = 2.0
    public var baselineDays: Int = 30
    public var minBaselineDays: Int = 7   // a z-term needs this much history else drops
    public var sleepSigmaFloorH: Double = 0.5
    public var zoneRecoverBelow: Int = 40
    public var zonePushAbove: Int = 70
    public var recentDaysKept: Int = 7    // local cache of daily rows re-upserted each refresh

    public init() {}

    public static let `default` = RecoveryTunables()
}
